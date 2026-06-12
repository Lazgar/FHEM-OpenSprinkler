package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use Digest::MD5 qw(md5_hex);

# Modul-Registrierung in FHEM
sub OpenSprinkler_Initialize($) {
    my ($hash) = @_;
    $hash->{DefFn}    = "OpenSprinkler_Define";
    $hash->{UndefFn}  = "OpenSprinkler_Undefine";
    $hash->{SetFn}    = "OpenSprinkler_Set";
    $hash->{GetFn}    = "OpenSprinkler_Get";
    $hash->{AttrList} = "interval " . $readingFnAttributes;
}

# Definition: define <name> OpenSprinkler <IP-Adresse> <Passwort>
sub OpenSprinkler_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    return "Usage: define <name> OpenSprinkler <IP> <Password>" if (@a < 4);

    my $name = $a[1];
    my $ip   = $a[2];
    my $pw   = $a[3];

    $hash->{NAME} = $name;
    $hash->{IP}   = $ip;
    $hash->{PW}   = md5_hex($pw); 

    # Standard-Intervall für Status-Updates: 60 Sekunden vordefinieren
    $attr{$name}{interval} = 60 if (!defined($attr{$name}{interval}));

    RemoveInternalTimer($hash);
    OpenSprinkler_Poll($hash);

    return undef;
}

sub OpenSprinkler_Undefine($$) {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

# Befehle verarbeiten (set ...)
sub OpenSprinkler_Set {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    my $cmd = $a[1]; # In FHEM-Set-Funktionen ist $a[1] der Befehl

    # Dynamische Befehlsliste generieren basierend auf erkannten Stations-Boards
    my $max_st = $hash->{helper}{max_stations} // 8;
    my @station_cmds;
    for (my $i = 0; $i < $max_st; $i++) {
        push(@station_cmds, "station_${i}_start", "station_${i}_stop");
    }
    
    # Kombiniert die Standard-Befehle mit den dynamischen Stations-Befehlen
    my $list = "rainDelay system_enabled:on,off " . join(" ", @station_cmds);

    return "Unknown argument $cmd, choose one of $list" if (!defined($cmd));

    # Basis-URL für die API-Steuerung des OpenSprinklers
    my $url = "http://" . $hash->{IP} . "/cm?pw=" . $hash->{PW};

    if ($cmd eq "system_enabled") {
        my $val = ($a[2] eq "on") ? 1 : 0;
        $url .= "&en=$val";
    }
    elsif ($cmd eq "rainDelay") {
        my $val = $a[2] // 0;
        $url .= "&rd=$val";
    }
    elsif ($cmd =~ /^station_(\d+)_start$/) {
        my $sid = $1;
        my $dur = $a[2] // 60; # Nutzt 60 Sekunden als Standard, falls keine Zeit übergeben wurde
        $url .= "&sid=$sid&t=$dur";
    }
    elsif ($cmd =~ /^station_(\d+)_stop$/) {
        my $sid = $1;
        $url .= "&sid=$sid&t=0";
    }
    else {
        return "Unknown argument $cmd, choose one of $list";
    }

    # Befehl asynchron absetzen, damit FHEM während des Netzwerk-Requests nicht blockiert
    HttpUtils_NonblockingGet({
        url => $url,
        timeout => 5,
        hash => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            if ($err) {
                Log3 $name, 3, "OpenSprinkler ($name): Set-Befehl fehlgeschlagen: $err";
            } else {
                # Sofortiger Status-Poll, damit das FHEM-Frontend direkt aktualisiert wird
                OpenSprinkler_Poll($hash);
            }
        }
    });

    return undef;
}

sub OpenSprinkler_Get($@) {
    my ($hash, @a) = @_;
    return "Unknown argument $a[1], choose status" if ($a[1] ne "status");
    OpenSprinkler_Poll($hash);
    return "Status-Update getriggert.";
}

# Zyklischer Haupt-Datenabruf (Status-Poll über /ja)
sub OpenSprinkler_Poll {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # Timer für den nächsten Poll setzen
    my $interval = AttrVal($name, "interval", 60);
    RemoveInternalTimer($hash);
    InternalTimer(time() + $interval, "OpenSprinkler_Poll", $hash, 0);

    HttpUtils_NonblockingGet({
        url => "http://" . $hash->{IP} . "/ja?pw=" . $hash->{PW},
        timeout => 5,
        hash => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            my $hash = $param->{hash};
            my $name = $hash->{NAME};

            if ($err) {
                Log3 $name, 3, "OpenSprinkler ($name): HTTP-Fehler beim Pollen: $err";
                readingsSingleUpdate($hash, "state", "error", 1);
                return;
            }

            if (!$data) {
                Log3 $name, 3, "OpenSprinkler ($name): Keine Daten empfangen.";
                readingsSingleUpdate($hash, "state", "disconnected", 1);
                return;
            }

            # ABSICHERUNG: eval verhindert den Absturz bei defektem/leerem JSON
            my $decoded;
            eval {
                $decoded = decode_json($data);
            };
            if ($@) {
                Log3 $name, 2, "OpenSprinkler ($name): JSON-Parsing fehlgeschlagen: $@";
                readingsSingleUpdate($hash, "state", "json error", 1);
                return;
            }

            readingsBeginUpdate($hash);

            # System Optionen verarbeiten
            if (exists($decoded->{options})) {
                my $opts = $decoded->{options};
                readingsBulkUpdate($hash, "firmware_version", $opts->{fwv} // "unknown");
                readingsBulkUpdate($hash, "hardware_version", $opts->{hwv} // "unknown");
                readingsBulkUpdate($hash, "mac_address", $opts->{mac} // "unknown");
                
                # Dynamische Ermittlung der Stationen (8 Basis + 8 pro Erweiterungsboard)
                my $nbrd = $opts->{nbrd} // 1;
                $hash->{helper}{max_stations} = $nbrd * 8;
                readingsBulkUpdate($hash, "station_boards", $nbrd);
            }

            # System Status & Werte verarbeiten
            if (exists($decoded->{settings})) {
                my $sets = $decoded->{settings};
                readingsBulkUpdate($hash, "current_mA", $sets->{mcur} // 0);
                readingsBulkUpdate($hash, "flow_total_clicks", $sets->{wcnt} // 0);
                readingsBulkUpdate($hash, "water_level_percent", $sets->{wl} // 100);
                
                my $en = $sets->{en} // 0;
                readingsBulkUpdate($hash, "system_enabled", $en ? "on" : "off");

                my $rd = $sets->{rd} // 0;
                if ($rd > 0) {
                    my $rd_time = $sets->{rdst} // 0;
                    my $rd_end = OpenSprinkler_SecToTime($rd_time);
                    readingsBulkUpdate($hash, "rainDelay", "on");
                    readingsBulkUpdate($hash, "rainDelay_until", $rd_end);
                } else {
                    readingsBulkUpdate($hash, "rainDelay", "off");
                    readingsBulkUpdate($hash, "rainDelay_until", "none");
                }

                my $rs = $sets->{rs} // 0;
                readingsBulkUpdate($hash, "rainSensor", $rs ? "rain" : "dry");

                # Letzter Lauf (Last Run)
                if (ref($sets->{lrun}) eq 'ARRAY' && scalar(@{$sets->{lrun}}) >= 4) {
                    my ($sid, $pid, $dur, $et) = @{$sets->{lrun}};
                    readingsBulkUpdate($hash, "last_run_station", $sid);
                    readingsBulkUpdate($hash, "last_run_duration_sec", $dur);
                }

                # Dynamische Stations-Readings (Zustand & Name)
                my $max_st = $hash->{helper}{max_stations} // 8;
                
                if (ref($sets->{sn}) eq 'ARRAY') {
                    for (my $i = 0; $i < $max_st; $i++) {
                        last if $i >= scalar(@{$sets->{sn}});
                        readingsBulkUpdate($hash, "station_" . $i . "_name", $sets->{sn}[$i]);
                    }
                }

                if (ref($sets->{sstat}) eq 'ARRAY') {
                    for (my $i = 0; $i < $max_st; $i++) {
                        last if $i >= scalar(@{$sets->{sstat}});
                        my $status = $sets->{sstat}[$i] ? "on" : "off";
                        readingsBulkUpdate($hash, "station_" . $i, $status);
                    }
                }
            }

            readingsBulkUpdate($hash, "state", "active");
            readingsEndUpdate($hash, 1);
        }
    });
}

# Hilfsfunktion zur Befehlsübertragung
sub OpenSprinkler_SendCommand($$$) {
    my ($hash, $url, $logMsg) = @_;
    
    HttpUtils_NonblockingGet({
        url     => $url,
        timeout => 5,
        hash    => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            my $hash = $param->{hash};
            
            if ($err) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] Befehl fehlgeschlagen: $err";
                return;
            }
            
            eval {
                my $res = decode_json($data);
                if (exists $res->{result} && $res->{result} == 1) {
                    Log3 $hash->{NAME}, 4, "OpenSprinkler [$hash->{NAME}]: $logMsg erfolgreich.";
                    OpenSprinkler_Poll($hash);
                }
            };
        }
    });
}

1;
