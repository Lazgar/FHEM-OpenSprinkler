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
sub OpenSprinkler_Set($@) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    
    # Befehlsstruktur für das FHEM-Frontend generieren (8 Stationen)
    my @cmd_list;
    for (my $i = 0; $i < 8; $i++) {
        push(@cmd_list, "station_" . $i . "_start:textField");
        push(@cmd_list, "station_" . $i . "_stop:noArg");
    }
    push(@cmd_list, "rainDelay:textField");
    push(@cmd_list, "system_enabled:on,off");
    
    my $usage = join(" ", @cmd_list);
    return $usage if (@a < 2);
    
    my $cmd = $a[1];
    
    # 1. STATION STARTEN (set <name> station_X_start <Sekunden>)
    if ($cmd =~ /^station_([0-7])_start$/) {
        my $sid = $1;
        return "Usage: set $name $cmd <seconds>" if (@a < 3);
        my $sekunden = $a[2]; 
        
        # Sichert den echten Sekunden-Wert nativ im Reading
        readingsSingleUpdate($hash, "station_" . $sid . "_duration", $sekunden, 1);
        
        my $url = "http://$hash->{IP}/cm?pw=$hash->{PW}&sid=$sid&en=1&t=$sekunden";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestartet fuer $sekunden Sekunden.");
        return undef;
    }
    
    # 2. STATION STOPPEN (set <name> station_X_stop)
    elsif ($cmd =~ /^station_([0-7])_stop$/) {
        my $sid = $1;
        
        readingsSingleUpdate($hash, "station_" . $sid . "_duration", 0, 1);
        
        my $url = "http://$hash->{IP}/cm?pw=$hash->{PW}&sid=$sid&en=0";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestoppt.");
        return undef;
    }
    
    # 3. GLOBALE REGEN-VERZÖGERUNG (set <name> rainDelay <Stunden>)
    elsif ($cmd eq "rainDelay") {
        return "Usage: set $name $cmd <hours>" if (@a < 3);
        my $hours = $a[2];
        my $url = "http://$hash->{IP}/cv?pw=$hash->{PW}&rd=$hours";
        OpenSprinkler_SendCommand($hash, $url, "Regen-Verzoegerung auf $hours Stunden gesetzt");
        return undef;
    }
    
    # 4. SYSTEM-BETRIEB (set <name> system_enabled on|off)
    elsif ($cmd eq "system_enabled") {
        return "Usage: set $name $cmd on|off" if (@a < 3);
        my $state = ($a[2] eq "on") ? 1 : 0;
        my $url = "http://$hash->{IP}/cv?pw=$hash->{PW}&en=$state";
        OpenSprinkler_SendCommand($hash, $url, "System-Betrieb auf $a[2] gesetzt");
        return undef;
    }

    return $usage;
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
