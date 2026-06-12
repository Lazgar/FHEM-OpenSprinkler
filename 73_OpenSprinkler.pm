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
    $hash->{AttrFn}   = "OpenSprinkler_Attr"; 
    $hash->{AttrList} = "interval " . $readingFnAttributes;
}

# Definition: define <name> OpenSprinkler <IP-Adresse> <Passwort>
sub OpenSprinkler_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    return "Usage: define <name> OpenSprinkler <IP> <Password>" if (@a < 4);

    # Feste Zuordnung der Parameter aus der define-Zeile
    my $dev_name = $a[0];
    my $dev_ip   = $dev_name; # Fallback falls nötig, aber wir nutzen direkt $a[2]
    
    $hash->{NAME} = $a[0];
    $hash->{IP}   = $a[2];
    $hash->{PW}   = md5_hex($a[3]); 

    $attr{$a[0]}{interval} = 60 if (!defined($attr{$a[0]}{interval}));

    RemoveInternalTimer($hash);
    OpenSprinkler_Poll($hash);

    return undef;
}

sub OpenSprinkler_Undefine($$) {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

# Überwachung für Attributänderungen zur Laufzeit
sub OpenSprinkler_Attr($$$$) {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    if ($attrName eq "interval" && defined($hash)) {
        if ($cmd eq "set") {
            RemoveInternalTimer($hash);
            InternalTimer(time() + int($attrVal), \&OpenSprinkler_Poll, $hash);
        } elsif ($cmd eq "del") {
            RemoveInternalTimer($hash);
            InternalTimer(time() + 60, \&OpenSprinkler_Poll, $hash);
        }
    }
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
    
    # 1. STATION STARTEN (set <name> station_X_start <Seconds>)
    if ($cmd =~ /^station_([0-7])_start$/) {
        my $sid = $1;
        return "Usage: set $name $cmd <seconds>" if (@a < 3);
        my $sekunden = $a[2]; # KORREKTUR: Greift absolut sicher auf das 3. Element zu
        
        # Sichert den Sekunden-Sollwert im Reading
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
        my $val_state = $a[2];
        my $state = ($val_state eq "on") ? 1 : 0;
        my $url = "http://$hash->{IP}/cv?pw=$hash->{PW}&en=$state";
        OpenSprinkler_SendCommand($hash, $url, "System-Betrieb auf $val_state gesetzt");
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
sub OpenSprinkler_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $url = "http://$hash->{IP}/ja?pw=$hash->{PW}";

    HttpUtils_NonblockingGet({
        url     => $url,
        timeout => 5,
        hash    => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            my $hash = $param->{hash};
            
            if ($err) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] Fehler beim Polling: $err";
                readingsSingleUpdate($hash, "state", "error", 1);
                return;
            }
            
            eval {
                my $json = decode_json($data);
                
                if (exists $json->{settings}) {
                    my $s = $json->{settings};
                    
                    readingsBeginUpdate($hash);
                    
                    # Globale Live-Hardware-Werte
                    readingsBulkUpdate($hash, "flow_total_clicks", $s->{flcto}) if exists $s->{flcto};
                    readingsBulkUpdate($hash, "current_mA", $s->{curr}) if exists $s->{curr};
                    readingsBulkUpdate($hash, "water_level_percent", $s->{wl}) if exists $s->{wl};
                    
                    # System-Informationen aus "options" parsen
                    if (exists $json->{options}) {
                        my $o = $json->{options};
                        readingsBulkUpdate($hash, "firmware_version", $o->{fwv}) if exists $o->{fwv};
                        readingsBulkUpdate($hash, "hardware_mac", $o->{mac}) if exists $o->{mac};
                        readingsBulkUpdate($hash, "extension_boards_count", $o->{npkg}) if exists $o->{npkg};
                        
                        if (exists $o->{devtype}) {
                            my %types = (1=>"OSPi (Raspberry)", 2=>"OpenSprinkler AC", 3=>"OpenSprinkler DC", 4=>"OpenSprinkler Lane");
                            readingsBulkUpdate($hash, "hardware_type", $types{$o->{devtype}} // "Unknown ($o->{devtype})");
                        }
                    }
                    
                    # Sensoren und Verzögerungen
                    readingsBulkUpdate($hash, "system_enabled", $s->{en} ? "on" : "off") if exists $s->{en};
                    readingsBulkUpdate($hash, "sensor_rain", $s->{rs} ? "rain" : "dry") if exists $s->{rs};
                    readingsBulkUpdate($hash, "rain_delay_active", $s->{rd} ? "on" : "off") if exists $s->{rd};
                    
                    if (exists $s->{rdst} && $s->{rdst} > 0) {
                        readingsBulkUpdate($hash, "rain_delay_until", "".localtime($s->{rdst}));
                    } else {
                        readingsBulkUpdate($hash, "rain_delay_until", "none");
                    }
                    
                    # Array-Indizes für lrun krisensicher über Variablen ausgelesen
                    if (exists $s->{lrun} && ref($s->{lrun}) eq 'ARRAY') {
                        my $lrun = $s->{lrun};
                        my $last_sid = $lrun->[0]; 
                        my $last_dur = $lrun->[2]; 
                        
                        if (defined $last_sid && $last_sid >= 0 && $last_sid < 8) {
                            readingsBulkUpdate($hash, "station_" . $last_sid . "_lastRealDuration", $last_dur);
                        }
                    }
                    
                    # Stationsnamen (snames) aus "stations"
                    if (exists $json->{stations} && exists $json->{stations}->{snames}) {
                        my $names = $json->{stations}->{snames};
                        for (my $i = 0; $i < @$names; $i++) {
                            readingsBulkUpdate($hash, "station_".$i."_name", $names->[$i]);
                        }
                    }
                    
                    # Ventilzustände (on/off) aus "status"
                    if (exists $json->{status} && exists $json->{status}->{sn}) {
                        my $stations = $json->{status}->{sn};
                        for (my $i = 0; $i < @$stations; $i++) {
                            readingsBulkUpdate($hash, "station_".$i."_state", $stations->[$i] ? "on" : "off");
                        }
                    }
                    
                    readingsBulkUpdate($hash, "state", "connected");
                    readingsEndUpdate($hash, 1);
                }
            };
            if ($@) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] JSON Parse Error: $@";
            }
        }
    });

    # Intervall dynamisch laden
    my $interval = 60;
    if (defined($attr{$name}) && defined($attr{$name}{interval})) {
        $interval = int($attr{$name}{interval});
    }
    InternalTimer(time() + $interval, \&OpenSprinkler_Poll, $hash);
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
