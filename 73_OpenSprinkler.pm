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

    my $name = $a[0];
    my $ip   = $a[2];
    my $pw   = $a[3];

    $hash->{NAME} = $name;
    $hash->{IP}   = $ip;
    $hash->{PW}   = md5_hex($pw);
    $hash->{helper}{max_stations} = 8;

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
    
    return "Unknown argument, choose one of ..." if (scalar(@a) < 2);
    
    my $cmd = $a[0]; # Der Befehl (z.B. station_0_start)
    my $arg = $a[1]; # Das Argument (z.B. Zeitdauer)

    # Dynamische Befehlsliste generieren basierend auf erkannten Stations-Boards
    my $max_st = $hash->{helper}{max_stations} // 8;
    my @station_cmds;
    for (my $i = 0; $i < $max_st; $i++) {
        push(@station_cmds, "station_${i}_start", "station_${i}_stop");
    }
    
    my $list = "rainDelay system_enabled:on,off " . join(" ", @station_cmds);

    return "Unknown argument $cmd, choose one of $list" if (!defined($cmd));

    my $url = "http://" . $hash->{IP} . "/cm?pw=" . $hash->{PW};

    if ($cmd eq "system_enabled") {
        my $val = ($arg eq "on") ? 1 : 0;
        $url .= "&en=$val";
    }
    elsif ($cmd eq "rainDelay") {
        my $val = $arg // 0;
        $url .= "&rd=$val";
    }
    elsif ($cmd =~ /^station_(\d+)_start$/) {
        my $sid = $1;
        my $dur = $arg // 60; 
        $url .= "&sid=$sid&t=$dur";
    }
    elsif ($cmd =~ /^station_(\d+)_stop$/) {
        my $sid = $1;
        $url .= "&sid=$sid&t=0";
    }
    else {
        return "Unknown argument $cmd, choose one of $list";
    }

    HttpUtils_NonblockingGet({
        url => $url,
        timeout => 5,
        hash => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            if ($err) {
                Log3 $name, 3, "OpenSprinkler ($name): Set-Befehl fehlgeschlagen: $err";
            } else {
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

            # Start des Bulk-Updates mit Event-Generierung am Ende
            readingsBeginUpdate($hash);

            # 1. System Optionen verarbeiten
            my $max_st = 8; 
            if (exists($decoded->{options})) {
                my $opts = $decoded->{options};
                readingsBulkUpdate($hash, "firmware_version", $opts->{fwv} // "unknown");
                readingsBulkUpdate($hash, "hardware_version", $opts->{hwv} // "unknown");
                readingsBulkUpdate($hash, "mac_address", $opts->{mac} // "unknown");
                
                my $nbrd = $opts->{nbrd} // 1;
                $max_st = $nbrd * 8;
                $hash->{helper}{max_stations} = $max_st;
                readingsBulkUpdate($hash, "station_boards", $nbrd);
            } else {
                $max_st = $hash->{helper}{max_stations} // 8;
            }

            # 2. System Status & Werte verarbeiten
            if (exists($decoded->{settings})) {
                my $sets = $decoded->{settings};
                readingsBulkUpdate($hash, "current_mA", $sets->{mcur} // 0);
                readingsBulkUpdate($hash, "flow_total_clicks", $sets->{wcnt} // 0);
                readingsBulkUpdate($hash, "water_level_percent", $sets->{wl} // 100);
                
                my $en = $sets->{en} // 0;
                readingsBulkUpdate($hash, "system_enabled", $en ? "on" : "off");

                my $rd = $sets->{rd} // 0;
                my $rd_end = "none";
                
                if ($rd > 0) {
                    my $rd_time = $sets->{rdst} // 0;
                    $rd_end = OpenSprinkler_SecToTime($rd_time);
                    readingsBulkUpdate($hash, "rainDelay", "on");
                } else {
                    readingsBulkUpdate($hash, "rainDelay", "off");
                }
                readingsBulkUpdate($hash, "rainDelay_until", $rd_end);

                my $rs = $sets->{rs} // 0;
                readingsBulkUpdate($hash, "rainSensor", $rs ? "rain" : "dry");

                # Letzter Lauf (Last Run)
                if (exists($sets->{lrun}) && ref($sets->{lrun}) eq 'ARRAY' && scalar(@{$sets->{lrun}}) >= 4) {
                    my ($sid, $pid, $dur, $et) = @{$sets->{lrun}};
                    readingsBulkUpdate($hash, "last_run_station", $sid);
                    readingsBulkUpdate($hash, "last_run_duration_sec", $dur);
                }
            }

            # 3. KORREKTUR: Stations-Namen und Status liegen auf ROOT-Ebene des JSON
            if (exists($decoded->{sn}) && ref($decoded->{sn}) eq 'ARRAY') {
                for (my $i = 0; $i < $max_st; $i++) {
                    last if $i >= scalar(@{$decoded->{sn}});
                    readingsBulkUpdate($hash, "station_" . $i . "_name", $decoded->{sn}[$i]);
                }
            }

            if (exists($decoded->{sstat}) && ref($decoded->{sstat}) eq 'ARRAY') {
                for (my $i = 0; $i < $max_st; $i++) {
                    last if $i >= scalar(@{$decoded->{sstat}});
                    my $status = $decoded->{sstat}[$i] ? "on" : "off";
                    readingsBulkUpdate($hash, "station_" . $i . "_state", $status);
                }
            }

            # State setzen und Updates abschließen (1 = Events erlauben!)
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
