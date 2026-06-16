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
    # Sicher mit Leerzeichen getrennt, um Autovervollständigungs-Fehler zu vermeiden
    $hash->{AttrList} = "interval active_stations " . " " . $readingFnAttributes;
}

# Definition: define <name> OpenSprinkler <IP-Adresse>
sub OpenSprinkler_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    return "Usage: define <name> OpenSprinkler <IP>" if (@a < 3);

    my $name = $a[0];
    $hash->{NAME} = $name;
    $hash->{IP}   = $a[2];

    $attr{$name}{interval} = 60 if (!defined($attr{$name}{interval}));

    # Abruf aus dem sicheren FHEM-KeyValue-Speicher
    my $pw_loaded = 0;
    if (defined(&getKeyValue)) {
        my $pw = getKeyValue($name . "_password");
        if ($pw) {
            $hash->{helper}{PW} = md5_hex($pw);
            $pw_loaded = 1;
        }
    }

    RemoveInternalTimer($hash, \&OpenSprinkler_Poll);

    # Polling nur starten, wenn das Passwort existiert
    if ($pw_loaded) {
        OpenSprinkler_Poll($hash);
    } else {
        Log3 $name, 3, "OpenSprinkler ($name) - Gerät initialisiert. Bitte setze das Passwort mit: set $name password <pw>";
        readingsSingleUpdate($hash, "state", "missing_password", 1);
    }

    return undef;
}

sub OpenSprinkler_Undefine($$) {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
    return undef;
}

sub OpenSprinkler_Attr($$$$) {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    # Generiert das Häkchen-Menü mit deinen Wünschen: station_0 bis station_7
    if ($attrName eq "active_stations") {
        if ($cmd eq "set" && (!defined($attrVal) || $attrVal eq "" || $attrVal eq "?")) {
            return "multiple,station_0,station_1,station_2,station_3,station_4,station_5,station_6,station_7";
        }
    }

    if ($attrName eq "interval" && defined($hash) && defined($hash->{helper}{PW})) {
        if ($cmd eq "set") {
            RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
            InternalTimer(time() + int($attrVal), \&OpenSprinkler_Poll, $hash, 0);
        } elsif ($cmd eq "del") {
            RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
            InternalTimer(time() + 60, \&OpenSprinkler_Poll, $hash, 0);
        }
    }
    return undef;
}

sub OpenSprinkler_Set($@) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    
    my @cmd_list;
    
    # 1. DYNAMISCHES MENÜ: Wenn kein Passwort im Speicher ist, NUR "password" anbieten!
    if (!defined($hash->{helper}{PW})) {
        push(@cmd_list, "password:textField"); 
        my $usage = join(" ", @cmd_list);
        return $usage if (@a < 2);
        
        my $cmd = $a[1];
        if ($cmd eq "password") {
            return "Usage: set $name password <your_password>" if (@a < 3);
            my $raw_pw = $a[2];
            
            if (defined(&setKeyValue)) {
                setKeyValue($name . "_password", $raw_pw);
                $hash->{helper}{PW} = md5_hex($raw_pw);
                Log3 $name, 3, "OpenSprinkler ($name) - Passwort erfolgreich verschlüsselt gespeichert.";
                
                RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
                OpenSprinkler_Poll($hash);
                
                FW_locationReload();
                return undef;
            } else {
                return "async:FW_msg('FHEM setKeyValue-Schnittstelle im Core nicht erreichbar.')";
            }
        }
        return "async:FW_msg('Bitte setze zuerst das Passwort mit: set $name password <pw>')";
    }
    
    # 2. STANDARD-MENÜ (Wird erst geladen, wenn das PW verifiziert ist)
    push(@cmd_list, "password:textField"); 
    for (my $i = 0; $i < 8; $i++) {
        push(@cmd_list, "station_" . $i . "_start:textField");
        push(@cmd_list, "station_" . $i . "_stop:noArg");
    }
    push(@cmd_list, "rainDelay:textField");
    push(@cmd_list, "system_enabled:on,off");
    
    my $usage = join(" ", @cmd_list);
    return $usage if (@a < 2);
    
    my $cmd = $a[1];
    
    # Passwort-Änderung im laufenden Betrieb
    if ($cmd eq "password") {
        return "Usage: set $name password <your_password>" if (@a < 3);
        my $raw_pw = $a[2];
        if (defined(&setKeyValue)) {
            setKeyValue($name . "_password", $raw_pw);
            $hash->{helper}{PW} = md5_hex($raw_pw);
            FW_locationReload();
            return undef;
        }
    }
    
    if ($cmd =~ /^station_([0-7])_start$/) {
        my $sid = $1;
        return "Usage: set $name $cmd <seconds>" if (@a < 3);
        my $sekunden = $a[2];
        
        readingsSingleUpdate($hash, "station_" . $sid . "_duration", $sekunden, 1);
        
        my $url = "http://$hash->{IP}/cm?pw=$hash->{helper}{PW}&sid=$sid&en=1&t=$sekunden";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestartet fuer $sekunden Sekunden.");
        return undef;
    }
    elsif ($cmd =~ /^station_([0-7])_stop$/) {
        my $sid = $1;
        readingsSingleUpdate($hash, "station_" . $sid . "_duration", 0, 1);
        my $url = "http://$hash->{IP}/cm?pw=$hash->{helper}{PW}&sid=$sid&en=0";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestoppt.");
        return undef;
    }
    elsif ($cmd eq "rainDelay") {
        return "Usage: set $name $cmd <hours>" if (@a < 3);
        my $hours = $a[2];
        my $url = "http://$hash->{IP}/cv?pw=$hash->{helper}{PW}&rd=$hours";
        OpenSprinkler_SendCommand($hash, $url, "Regen-Verzoegerung auf $hours Stunden gesetzt");
        return undef;
    }
    elsif ($cmd eq "system_enabled") {
        return "Usage: set $name $cmd on|off" if (@a < 3);
        my $val_state = $a[2];
        my $state = ($val_state eq "on") ? 1 : 0;
        my $url = "http://$hash->{IP}/cv?pw=$hash->{helper}{PW}&en=$state";
        OpenSprinkler_SendCommand($hash, $url, "System-Betrieb auf $val_state gesetzt");
        return undef;
    }

    return $usage;
}

sub OpenSprinkler_Get($@) {
    my ($hash, @a) = @_;
    return "Unknown argument $a[1], choose status" if ($a[1] ne "status");
    
    if (!defined($hash->{helper}{PW})) {
        return "Fehler: Status-Abruf nicht möglich. Kein Passwort hinterlegt.";
    }
    
    OpenSprinkler_Poll($hash);
    return "Status-Update getriggert.";
}

# Zyklischer Haupt-Datenabruf (Status-Poll über /ja)
sub OpenSprinkler_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # SCHUTZWALL: Wenn kein Passwort vorhanden ist, breche den HTTP-Poll sofort ab!
    if (!defined($hash->{helper}{PW})) {
        Log3 $name, 4, "OpenSprinkler ($name) - Polling blockiert: Kein Passwort im Speicher.";
        return undef;
    }

    my $url = "http://$hash->{IP}/ja?pw=$hash->{helper}{PW}";

    HttpUtils_NonblockingGet({
        url     => $url,
        timeout => 5,
        hash    => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            my $hash = $param->{hash};
            my $pname = $hash->{NAME};
            
            if ($err) {
                Log3 $pname, 3, "OpenSprinkler [$pname] Fehler beim Polling: $err";
                readingsSingleUpdate($hash, "state", "error", 1);
                return;
            }
            
            eval {
                my $json = decode_json($data);
                
                if (exists $json->{settings}) {
                    my $s = $json->{settings};
                    
                    # BLOCK 1: Globale Live-Hardware- und System-Werte
                    readingsBeginUpdate($hash);
                    
                    readingsBulkUpdate($hash, "current_mA", $s->{curr}) if exists $s->{curr};
                    
                    if (exists $json->{options}) {
                        my $o = $json->{options};
                        readingsBulkUpdate($hash, "firmware_version", $o->{fwv}) if exists $o->{fwv};
                        readingsBulkUpdate($hash, "hardware_version", $o->{hwv}) if exists $o->{hwv};
                        readingsBulkUpdate($hash, "extension_boards", $o->{ext}) if exists $o->{ext};
                        readingsBulkUpdate($hash, "water_level_percent", $o->{wl}) if exists $o->{wl};
                        
                        if (exists $o->{hwt}) {
                            my %types = (1=>"OSPi (Raspberry)", 172=>"AC Power Version", 220=>"DC Power Version", 26=>"Latch Version");
                            readingsBulkUpdate($hash, "hardware_type", $types{$o->{hwt}} // "Unknown ($o->{hwt})");
                        }
                    }
                    
                    readingsBulkUpdate($hash, "system_enabled", $s->{en} ? "on" : "off") if exists $s->{en};
                    readingsBulkUpdate($hash, "rain_delay_active", $s->{rd} ? "on" : "off") if exists $s->{rd};
                    
                    if (exists $s->{rdst} && $s->{rdst} > 0) {
                        readingsBulkUpdate($hash, "rain_delay_until", "".localtime($s->{rdst}));
                    } else {
                        readingsBulkUpdate($hash, "rain_delay_until", "none");
                    }
                    
                    # AUSWERTUNG AKTIVE STATIONEN (Matched jetzt exakt auf station_X):
                    my $active_attr = AttrVal($pname, "active_stations", "station_0,station_1,station_2,station_3,station_4,station_5,station_6,station_7");
                    my %active_stations = map { $_ => 1 } split(",", $active_attr);
                    
                    if (exists $s->{lrun} && ref($s->{lrun}) eq 'ARRAY') {
                        my $lrun = $s->{lrun};
                        my $last_sid = $lrun->[0];
                        my $last_dur = $lrun->[2];
                        
                        if (defined $last_sid && $last_sid >= 0 && $last_sid < 8) {
                            if (exists $active_stations{"station__".$last_sid}) {
                                readingsBulkUpdate($hash, "station_" . $last_sid . "_lastDuration", $last_dur);
                            }
                        }
                    }
                    
                    readingsEndUpdate($hash, 1);
                    # BLOCK 2: Stationsnamen (snames) aus "stations"
                    if (exists $json->{stations} && exists $json->{stations}->{snames}) {
                        readingsBeginUpdate($hash);
                        my $names = $json->{stations}->{snames};
                        
                        for (my $i = 0; $i < @$names; $i++) {
                            if (exists $active_stations{"station_".$i}) {
                                readingsBulkUpdate($hash, "station_".$i."_name", $names->[$i]);
                            }
                        }
                    
                        readingsEndUpdate($hash, 1);
                    }
                    # BLOCK 3: Ventilzustände (on/off) aus "status"
                    if (exists $json->{status} && exists $json->{status}->{sn}) {
                        readingsBeginUpdate($hash);
                        my $stations = $json->{status}->{sn};
                            
                        for (my $i = 0; $i < @$stations; $i++) {
                            if (exists $active_stations{"station_".$i}) {
                                readingsBulkUpdate($hash, "station_".$i."_state", $stations->[$i] ? "on" : "off");
                            }
                        }
                        my $nstations = $json->{status};
                        readingsBulkUpdate($hash, "nstations", $nstations->{nstations}) if exists $nstations->{nstations};
                        readingsBulkUpdate($hash, "state", "connected");
                        readingsEndUpdate($hash, 1);
                    }
                        
                    # BLOCK 4: AUTOMATISCHE BEREINIGUNG
                    for (my $i = 0; $i < 8; $i++) {
                    
                        if (!exists $active_stations{"station_".$i}) {
                            fhemDeleteReading($hash, "station_".$i."name");
                            fhemDeleteReading($hash, "station".$i."state");
                            fhemDeleteReading($hash, "station".$i."duration");
                            fhemDeleteReading($hash, "station".$i."_lastDuration");
                        }
                    }
                }
            };
                
            if ($@) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] JSON Parse Error: $@";
            }
        }
    });
    # Neuen Timer für die nächste Runde anmelden
    my $interval = 60;
    
    if (defined($attr{$name}) && defined($attr{$name}{interval})) {
        $interval = int($attr{$name}{interval});
    }
    RemoveInternalTimer($hash, &OpenSprinkler_Poll);
    InternalTimer(time() + $interval, &OpenSprinkler_Poll, $hash, 0);
}
        
#Hilfsfunktion zur Befehlsübertragung
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
            } eval {
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
