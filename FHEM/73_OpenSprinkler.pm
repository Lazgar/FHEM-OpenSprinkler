package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64 qw(encode_base64);
use Digest::MD5 qw(md5_hex);

# Modul-Registrierung in FHEM
sub OpenSprinkler_Initialize($) {
    my ($hash) = @_;
    $hash->{DefFn}    = "OpenSprinkler_Define";
    $hash->{UndefFn}  = "OpenSprinkler_Undefine";
    $hash->{SetFn}    = "OpenSprinkler_Set";
    $hash->{GetFn}    = "OpenSprinkler_Get";
    $hash->{AttrFn}   = "OpenSprinkler_Attr"; 

    my $stations = "station_0,station_1,station_2,station_3,station_4,station_5,station_6,station_7";    
    $hash->{AttrList} = "disable:1,0 interval stations:multiple-strict,$stations " . $readingFnAttributes;
}

# Hilfsfunktion: Aktualisiert die AttrList im laufenden Betrieb
sub OpenSprinkler_UpdateAttrList($$) {
    my ($hash, $max_stations) = @_;
    my @st_array;
    for (my $i = 0; $i < $max_stations; $i++) {
        push(@st_array, "station_$i");
    }
    my $stations_string = join(",", @st_array);
    $hash->{AttrList} = "disable:1,0 interval stations:multiple-strict,$stations_string " . $readingFnAttributes;
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

    # NEU: Standardwert fÃ¼r Schleifen vor dem ersten API-Poll festlegen
    $hash->{helper}{MAX_STATIONS} = 8; 

    # DER ECHTE MODERNSTE WEG: Abruf aus dem FHEM-KeyValue-Speicher
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
        Log3 $name, 3, "OpenSprinkler ($name) - GerÃ¤t initialisiert. Bitte setze das Passwort mit: set $name password <pw>";
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
    my $max_stations = $hash->{helper}{MAX_STATIONS} // 8;

    # Validierung: ein Intervall von 0 oder Text wuerde den Controller dauernd abfragen
    if ($attrName eq "interval" && $cmd eq "set") {
        return "interval must be a number of seconds (minimum 5)" if (!defined($attrVal) || $attrVal !~ /^\d+$/ || $attrVal < 5);
    }

    if ($attrName eq "disable" && defined($hash)) {
        # disable sperrt nur die Steuerbefehle; das Polling laeuft weiter
        my $locked = ($cmd eq "set" && $attrVal) ? 1 : 0;
        readingsSingleUpdate($hash, "locked", $locked, 1) if ($init_done);
        if (defined($hash->{helper}{PW}) && $init_done) {
            RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
            InternalTimer(time() + 1, \&OpenSprinkler_Poll, $hash, 0);
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

    # 2. NEUE LOGIK: AbgewÃ¤hlte Stationen sofort lÃ¶schen
    if ($attrName eq "stations" && defined($hash)) {
        # Wenn das Attribut gelÃ¶scht wird (del) oder leer ist, behalten wir alle.
        # Wenn es gesetzt wird (set), rÃ¤umen wir die nicht gewÃ¤hlten auf.
        if ($cmd eq "set" && $attrVal ne "") {
            
            # Wir prÃ¼fen alle 8 potenziellen Stationen
            for (my $i = 0; $i < $max_stations; $i++) {
                
                # Wenn die Station NICHT im neuen Attributwert vorkommt
                if ($attrVal !~ /station_$i/) {
                    
                    # FHEM-interne LÃ¶schbefehle fÃ¼r alle zugehÃ¶rigen Readings dieser Station
                    # Format: CommandDeleteReading(undef, "<GerÃ¤tename> <ReadingName>")
                    CommandDeleteReading(undef, "$name station_" . $i . "_name")     if exists $hash->{READINGS}{"station_" . $i . "_name"};
                    CommandDeleteReading(undef, "$name station_" . $i . "_state")    if exists $hash->{READINGS}{"station_" . $i . "_state"};
                    CommandDeleteReading(undef, "$name station_" . $i . "_duration") if exists $hash->{READINGS}{"station_" . $i . "_duration"};
                    CommandDeleteReading(undef, "$name station_" . $i . "_lastDuration") if exists $hash->{READINGS}{"station_" . $i . "_lastDuration"};
                    CommandDeleteReading(undef, "$name station_" . $i . "_runSince")     if exists $hash->{READINGS}{"station_" . $i . "_runSince"};
                    CommandDeleteReading(undef, "$name station_" . $i . "_lastRun")      if exists $hash->{READINGS}{"station_" . $i . "_lastRun"};
                }
            }
            # NEU: Zwingt die FHEMWEB-OberflÃ¤che zum Neuaufbau des SET-Dropdowns
            if (defined(&FW_locationReload)) {
                FW_locationReload();
            }
        }
    }
    return undef;
}

sub OpenSprinkler_Set($@) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    my $max_stations = $hash->{helper}{MAX_STATIONS} // 8;

    return "\"set $name\" needs at least one argument" if (@a < 2);
    my $cmd = $a[1];

    # Passwort setzen: immer moeglich, auch ohne vorhandenes Passwort
    if ($cmd eq "password") {
        return "Usage: set $name password <your_password>" if (@a < 3);
        my $raw_pw = $a[2];

        # Speichern im offiziellen FHEM-Speicher (keystore)
        return "FHEM setKeyValue interface not available" if (!defined(&setKeyValue));
        setKeyValue($name . "_password", $raw_pw);
        $hash->{helper}{PW} = md5_hex($raw_pw);
        Log3 $name, 3, "OpenSprinkler ($name) - Passwort gespeichert.";

        RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
        OpenSprinkler_Poll($hash);

        # FHEMWEB zwingt den Browser zu einem Reload, damit alle Befehle erscheinen
        FW_locationReload() if (defined(&FW_locationReload));
        return undef;
    }

    # Ohne Passwort wird nur "password" angeboten
    my @cmd_list = ("password:textField");

    if (defined($hash->{helper}{PW})) {
        # Nur aktive Stationen (Attribut "stations", leer = alle) ins Menue aufnehmen
        my $stations_attr = AttrVal($name, "stations", "");
        for (my $i = 0; $i < $max_stations; $i++) {
            if ($stations_attr eq "" || $stations_attr =~ /station_$i\b/) {
                push(@cmd_list, "station_" . $i . "_start:textField");
                push(@cmd_list, "station_" . $i . "_stop:noArg");
            }
        }
        push(@cmd_list, "rainDelay:textField");
        push(@cmd_list, "system_enabled:on,off");
    }

    my $usage = join(" ", @cmd_list);

    if (!defined($hash->{helper}{PW}) || $cmd !~ /^(station_(\d+)_(start|stop)|rainDelay|system_enabled)$/) {
        return "Unknown argument $cmd, choose one of $usage";
    }

    # disable 1: Status wird weiter abgefragt, aber keine Steuerbefehle an den Controller
    if (AttrVal($name, "disable", 0)) {
        Log3 $name, 3, "OpenSprinkler ($name) - set $cmd abgelehnt: disabled (Befehle gesperrt)";
        return "$name is disabled: Befehle gesperrt (attr $name disable 0 zum Freigeben)";
    }

    if ($cmd =~ /^station_(\d+)_start$/) {
        my $sid = $1;
        return "Station $sid is not available" if ($sid >= $max_stations);
        return "Usage: set $name $cmd <seconds>" if (@a < 3);
        my $sekunden = $a[2];
        return "$cmd: seconds must be a whole number between 1 and 64800" if ($sekunden !~ /^\d+$/ || $sekunden < 1 || $sekunden > 64800);

        my $url = "http://$hash->{IP}/cm?pw=$hash->{helper}{PW}&sid=$sid&en=1&t=$sekunden";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestartet fuer $sekunden Sekunden.", sub {
            readingsSingleUpdate($hash, "station_" . $sid . "_duration", $sekunden, 1);
        });
        return undef;
    }
    elsif ($cmd =~ /^station_(\d+)_stop$/) {
        my $sid = $1;
        return "Station $sid is not available" if ($sid >= $max_stations);
        my $url = "http://$hash->{IP}/cm?pw=$hash->{helper}{PW}&sid=$sid&en=0";
        OpenSprinkler_SendCommand($hash, $url, "Station $sid gestoppt.", sub {
            readingsSingleUpdate($hash, "station_" . $sid . "_duration", 0, 1);
        });
        return undef;
    }
    elsif ($cmd eq "rainDelay") {
        return "Usage: set $name $cmd <hours>" if (@a < 3);
        my $hours = $a[2];
        return "$cmd: hours must be a whole number between 0 and 32767" if ($hours !~ /^\d+$/ || $hours > 32767);
        my $url = "http://$hash->{IP}/cv?pw=$hash->{helper}{PW}&rd=$hours";
        OpenSprinkler_SendCommand($hash, $url, "Regen-Verzoegerung auf $hours Stunden gesetzt");
        return undef;
    }
    elsif ($cmd eq "system_enabled") {
        return "Usage: set $name $cmd on|off" if (@a < 3 || $a[2] !~ /^(on|off)$/);
        my $val_state = $a[2];
        my $state = ($val_state eq "on") ? 1 : 0;
        my $url = "http://$hash->{IP}/cv?pw=$hash->{helper}{PW}&en=$state";
        OpenSprinkler_SendCommand($hash, $url, "System-Betrieb auf $val_state gesetzt");
        return undef;
    }

    return "Unknown argument $cmd, choose one of $usage";
}

sub OpenSprinkler_Get($@) {
    my ($hash, @a) = @_;
    return "\"get $hash->{NAME}\" needs at least one argument" if (@a < 2);
    return "Unknown argument $a[1], choose one of status:noArg" if ($a[1] ne "status");
    
    if (!defined($hash->{helper}{PW})) {
        return "Fehler: Status-Abruf nicht mÃ¶glich. Kein Passwort hinterlegt.";
    }
    
    OpenSprinkler_Poll($hash);
    return "Status-Update getriggert.";
}

# Zyklischer Haupt-Datenabruf (Status-Poll Ã¼ber /ja)
sub OpenSprinkler_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if (!defined($hash->{helper}{PW})) {
        Log3 $name, 4, "OpenSprinkler ($name) - Polling blockiert: Kein Passwort im Speicher.";
        return undef;
    }

    # NEUSTARTSCHUTZ: Wenn FHEM gerade noch im Boot-Vorgang (global:init) ist, 
    # brechen wir ab und starten den Poll in 5 Sekunden neu, wenn alle Attribute geladen sind!
    if ($init_done == 0) {
        RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
        InternalTimer(time() + 5, \&OpenSprinkler_Poll, $hash, 0);
        Log3 $name, 4, "OpenSprinkler ($name) - Systemstart aktiv. Verschiebe ersten Poll um 5 Sekunden.";
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
            
            # WICHTIG: Wenn ein Netzwerkfehler vorliegt, brechen wir kontrolliert ab!
            if ($err) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] Fehler beim Polling: $err";
                readingsSingleUpdate($hash, "state", "error", 1);
                return; # Schließt den HTTP-Socket sauber
            }
            
            my $json;
            # Schritt 1: Reines JSON-Parsing isolieren (Verhindert Socket-Leaks bei korrupten API-Daten)
            eval {
                $json = decode_json($data);
            };
            if ($@ || !$json) {
                Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}] JSON Parse Error oder leere Daten: $@";
                readingsSingleUpdate($hash, "state", "error", 1);
                return; # Schließt den Socket sauber
            }
            
            # Antwort ohne Daten, aber mit Ergebniscode: {"result":2} = Passwort falsch usw.
            if (ref($json) eq 'HASH' && !exists $json->{settings} && exists $json->{result}) {
                my %res = (2 => "wrong_password", 3 => "error (missing parameter)", 16 => "error (data missing)");
                my $st = $res{$json->{result}} // "error (result $json->{result})";
                Log3 $hash->{NAME}, 2, "OpenSprinkler [$hash->{NAME}] Controller meldet $st";
                readingsSingleUpdate($hash, "state", $st, 1);
                return;
            }

            # Schritt 2: Sichere Datenverarbeitung
            if (exists $json->{settings}) {
                my $s = $json->{settings};
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

                    if (exists $o->{ext}) {
                        my $ext_boards = int($o->{ext});
                        # Die Firmware zaehlt Boards zu je 8 Stationen; die tatsaechliche Anzahl steht in status.nstations
                        my $calc_stations = (ref($json->{status}) eq 'HASH' && defined($json->{status}{nstations}) && $json->{status}{nstations} =~ /^\d+$/)
                                          ? int($json->{status}{nstations})
                                          : 8 + ($ext_boards * 8);
                        
                        if (!defined($hash->{helper}{MAX_STATIONS}) || $hash->{helper}{MAX_STATIONS} != $calc_stations) {
                            $hash->{helper}{MAX_STATIONS} = $calc_stations;
                            OpenSprinkler_UpdateAttrList($hash, $calc_stations);
                            Log3 $hash->{NAME}, 3, "OpenSprinkler [$hash->{NAME}]: Erweiterungsboards erkannt ($ext_boards). Stationsanzahl auf $calc_stations angepasst.";
                        }
                    }
                }
                
                my $max_stations = $hash->{helper}{MAX_STATIONS} // 8;
                
                readingsBulkUpdate($hash, "system_enabled", $s->{en} ? "on" : "off") if exists $s->{en};
                readingsBulkUpdate($hash, "rain_delay_active", $s->{rd} ? "on" : "off") if exists $s->{rd};
                
                if (exists $s->{rdst} && $s->{rdst} > 0) {
                    readingsBulkUpdate($hash, "rain_delay_until", "".localtime($s->{rdst}));
                } else {
                    readingsBulkUpdate($hash, "rain_delay_until", "none");
                }
                
                if (exists $s->{lrun} && ref($s->{lrun}) eq 'ARRAY') {
                    my $lrun = $s->{lrun};
                    my $last_sid = $lrun->[0]; 
                    my $last_dur = $lrun->[2]; 
                    if (defined $last_sid && $last_sid >= 0 && $last_sid < $max_stations) {
                        readingsBulkUpdate($hash, "station_" . $last_sid . "_lastDuration", $last_dur);
                    }
                }
                readingsEndUpdate($hash, 1);

                my $active_attr = AttrVal($hash->{NAME}, "stations", "");

                # BLOCK 2: Stationsnamen
                if (exists $json->{stations} && exists $json->{stations}->{snames}) {
                    readingsBeginUpdate($hash);
                    my $names = $json->{stations}->{snames};
                    for (my $i = 0; $i < @$names; $i++) {
                        if ($i < $max_stations && ($active_attr eq "" || $active_attr =~ /station_$i/)) {
                            readingsBulkUpdate($hash, "station_".$i."_name", $names->[$i]);
                        }
                    }
                    readingsEndUpdate($hash, 1);
                }

                # BLOCK 3: Ventilzustände und minutengenau fortlaufende Kalendertag-Berechnungen
                if (exists $json->{status} && exists $json->{status}->{sn}) {
                    readingsBeginUpdate($hash);
                    my $stations = $json->{status}->{sn};
                        
                    for (my $i = 0; $i < @$stations; $i++) {
                        if ($i < $max_stations && ($active_attr eq "" || $active_attr =~ /station_$i/)) {
                            my $state_val = $stations->[$i] ? "on" : "off";
                            my $old_state = ReadingsVal($hash->{NAME}, "station_" . $i . "_state", "unknown");
                            
                            # Zeitstempel der Status-Reading-Änderung NUR bei echtem Wechsel aktualisieren!
                            if ($state_val ne $old_state) {
                                readingsBulkUpdate($hash, "station_".$i."_state", $state_val);
                            }
                            
                            # Hole den neustartsicheren FHEM-Timestamp
                            my $ts = ReadingsTimestamp($hash->{NAME}, "station_" . $i . "_state", 0);
                                
                            if ($state_val eq "on") {
                                    # 1. LIVE-BERECHNUNG: _runSince (Format HH:MM oder MM Min.)
                                    if ($ts ne "0") {
                                        my $diff = time() - time_str2num($ts);
                                        
                                        my $hours   = int($diff / 3600);
                                        my $minutes = int(($diff % 3600) / 60);
                                        
                                        my $val;
                                        if ($hours > 0) {
                                            # Format für lange Laufzeiten (z. B. 10:15 statt 10:15:30)
                                            $val = sprintf("%02d:%02d", $hours, $minutes);
                                        } else {
                                            # Standard-Format unter einer Stunde (z. B. 15 Min.)
                                            $val = sprintf("%02d Min.", $minutes);
                                        }
                                        
                                        readingsBulkUpdate($hash, "station_" . $i . "_runSince", $val);
                                    }
                                    readingsBulkUpdate($hash, "station_" . $i . "_lastRun", "running");
                                }
                            else {
                                # Wenn sie steht, leeren wir die Live-Laufzeit
                                readingsBulkUpdate($hash, "station_" . $i . "_runSince", "");
                                    
                                # 2. ISOLIERTE API-UNABHÄNGIGE LIVE-BERECHNUNG: _lastRun (Fortlaufende Tage-Differenz)
                                # Wir berechnen den Wert JETZT bei jedem Poll live, damit er nachts automatisch hochzählt!
                                if ($ts ne "0" && $old_state ne "unknown" && main->can("SYSMON_decode_time_diff")) {
                                    # Holt den Startzeitpunkt (00:00:01) des Tages, an dem die Station das LETZTE Mal geschaltet hat
                                    my $day_start = substr($ts, 0, 10) . " 00:00:01";
                                    my $diff = time() - time_str2num($day_start);
                                    
                                    eval {
                                        my @var = split(/ /, sprintf("%d %01d:%02d", SYSMON_decode_time_diff($diff)));
                                        # Schreibt den fortlaufenden Tageswert (0, 1, 2...) aktiv in das Reading
                                        readingsBulkUpdate($hash, "station_" . $i . "_lastRun", $var[0]);
                                    };
                                }
                                else {
                                    # Fallback bei der Ersteinrichtung
                                    my $current_lastrun = ReadingsVal($hash->{NAME}, "station_" . $i . "_lastRun", "");
                                    if ($current_lastrun eq "" || $current_lastrun eq "running") {
                                        readingsBulkUpdate($hash, "station_" . $i . "_lastRun", "no Data");
                                    }
                                }
                            }
                        }
                    }
                    my $nstations = $json->{status};
                    readingsBulkUpdate($hash, "total_stations", $nstations->{nstations}) if exists $nstations->{nstations};
                    readingsBulkUpdate($hash, "state", "connected");
                    readingsBulkUpdate($hash, "locked", AttrVal($hash->{NAME}, "disable", 0) ? 1 : 0);
                    readingsEndUpdate($hash, 1);
                }
            }
        }
    });

    # Re-Poller registrieren (Das muss zwingend außerhalb der anonymen Callback-Schnittstelle stattfinden)
    my $interval = 60;
    if (defined($attr{$name}) && defined($attr{$name}{interval})) {
        $interval = int($attr{$name}{interval});
    }

    RemoveInternalTimer($hash, \&OpenSprinkler_Poll);
    InternalTimer(time() + $interval, \&OpenSprinkler_Poll, $hash, 0);
}

# Hilfsfunktion zur Befehlsuebertragung; $on_ok wird nur bei {"result":1} aufgerufen
sub OpenSprinkler_SendCommand($$$;$) {
    my ($hash, $url, $logMsg, $on_ok) = @_;

    HttpUtils_NonblockingGet({
        url     => $url,
        timeout => 5,
        hash    => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            my $hash = $param->{hash};
            my $name = $hash->{NAME};

            if ($err) {
                Log3 $name, 3, "OpenSprinkler [$name] Befehl fehlgeschlagen: $err";
                readingsSingleUpdate($hash, "last_command_result", "error: $err", 1);
                return;
            }

            my $res = eval { decode_json($data) };
            if (ref($res) eq 'HASH' && defined $res->{result} && $res->{result} == 1) {
                Log3 $name, 4, "OpenSprinkler [$name]: $logMsg erfolgreich.";
                readingsSingleUpdate($hash, "last_command_result", "ok", 1);
                $on_ok->() if (ref($on_ok) eq 'CODE');
                OpenSprinkler_Poll($hash);
            } else {
                my $code = (ref($res) eq 'HASH' && defined $res->{result}) ? $res->{result} : "unparsable answer";
                Log3 $name, 2, "OpenSprinkler [$name]: Befehl abgelehnt (result $code): $logMsg";
                readingsSingleUpdate($hash, "last_command_result", "error: result $code", 1);
            }
        }
    });
}

1;

=pod
=item device
=item summary    Integration of an OpenSprinkler irrigation controller (local HTTP API)
=item summary_DE Anbindung eines OpenSprinkler-Bew&auml;sserungscontrollers (lokale HTTP-API)
=begin html

<a name="OpenSprinkler"></a>
<h3>OpenSprinkler</h3>
<ul>
  Non-blocking integration of an OpenSprinkler (firmware 2.x/3.x) over its local HTTP API.<br><br>
  <a name="OpenSprinklerdefine"></a>
  <b>Define</b>
  <ul><code>define &lt;name&gt; OpenSprinkler &lt;ip&gt;</code><br>
  Polling starts after the password has been stored: <code>set &lt;name&gt; password &lt;pw&gt;</code> (kept in the FHEM key store, only the MD5 hash is sent).</ul><br>
  <a name="OpenSprinklerset"></a>
  <b>Set</b>
  <ul>
    <li><code>password &lt;pw&gt;</code></li>
    <li><code>station_&lt;N&gt;_start &lt;seconds&gt;</code> (1..64800), <code>station_&lt;N&gt;_stop</code></li>
    <li><code>rainDelay &lt;hours&gt;</code> (0..32767)</li>
    <li><code>system_enabled on|off</code></li>
  </ul><br>
  <a name="OpenSprinklerget"></a>
  <b>Get</b>
  <ul><li><code>status</code> &ndash; immediate poll</li></ul><br>
  <a name="OpenSprinklerattr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code> &ndash; polling interval in seconds (minimum 5, default 60)</li>
    <li><code>stations</code> &ndash; selection of the active stations (check boxes); empty = all stations</li>
    <li><code>disable</code> &ndash; 1 blocks all control commands (set station/rainDelay/system_enabled); polling continues, reading <code>locked</code> = 1</li>
  </ul><br>
  <b>Readings</b>
  <ul>
    <li><code>state</code>: connected, error, disabled, missing_password, wrong_password</li>
    <li><code>last_command_result</code>: ok or error: &hellip; for the last set command</li>
    <li><code>current_mA</code>, <code>water_level_percent</code>, <code>firmware_version</code>, <code>hardware_version</code>, <code>hardware_type</code>, <code>extension_boards</code>, <code>total_stations</code>, <code>system_enabled</code>, <code>rain_delay_active</code>, <code>rain_delay_until</code></li>
    <li>per station: <code>station_N_name</code>, <code>_state</code>, <code>_duration</code>, <code>_lastDuration</code>, <code>_runSince</code>, <code>_lastRun</code></li>
  </ul>
</ul>

=end html
=cut
