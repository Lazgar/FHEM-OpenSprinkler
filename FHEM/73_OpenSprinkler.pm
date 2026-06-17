sub OpenSprinkler_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

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
                return; # Schließt den Socket sauber
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
                        my $calc_stations = 8 + ($ext_boards * 16);
                        
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

                my $active_attr = AttrVal($hash->{NAME}, "active_stations", "");

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

                # BLOCK 3: Ventilzustände & Rechnungen mit fehlerisoliertem, gekapseltem Eval
                if (exists $json->{status} && exists $json->{status}->{sn}) {
                    readingsBeginUpdate($hash);
                    my $stations = $json->{status}->{sn};
                    for (my $i = 0; $i < @$stations; $i++) {
                        if ($i < $max_stations && ($active_attr eq "" || $active_attr =~ /station_$i/)) {
                            my $state_val = $stations->[$i] ? "on" : "off";
                            my $old_state = ReadingsVal($hash->{NAME}, "station_" . $i . "_state", "unknown");
                            
                            if ($state_val ne $old_state) {
                                readingsBulkUpdate($hash, "station_".$i."_state", $state_val);
                            }
                            
                            my $ts = ReadingsTimestamp($hash->{NAME}, "station_" . $i . "_state", 0);
                            
                            if ($state_val eq "on") {
                                # JEDE BERECHNUNG ISOLIERT IN EINEM EIGENEN EVAL, DAMIT DIE SCHLEIFE UND DER CALL-STACK WEITERLAUFEN!
                                if ($ts ne "0" && main->can("SYSMON_decode_time_diff")) {
                                    my $diff = time() - time_str2num($ts);
                                    eval {
                                        my $val = substr(sprintf("%d %01d:%02d", SYSMON_decode_time_diff($diff)), 2, 4);
                                        readingsBulkUpdate($hash, "station_" . $i . "_runSince", $val);
                                    };
                                }
                                readingsBulkUpdate($hash, "station_" . $i . "_lastRun", "läuft gerade");
                            } 
                            else {
                                readingsBulkUpdate($hash, "station_" . $i . "_runSince", "");
                                if ($old_state eq "on") {
                                    if ($ts ne "0" && main->can("SYSMON_decode_time_diff")) {
                                        my $day_start = substr($ts, 0, 10) . " 00:00:01";
                                        my $diff = time() - time_str2num($day_start);
                                        eval {
                                            my @var = split(/ /, sprintf("%d %01d:%02d", SYSMON_decode_time_diff($diff)));
                                            readingsBulkUpdate($hash, "station_" . $i . "_lastRun", $var[0]);
                                        };
                                        if ($@) {
                                            readingsBulkUpdate($hash, "station_" . $i . "_lastRun", "Fehler");
                                        }
                                    }
                                }
                                else {
                                    my $current_lastrun = ReadingsVal($hash->{NAME}, "station_" . $i . "_lastRun", "");
                                    if ($current_lastrun eq "" || $current_lastrun eq "läuft gerade") {
                                        readingsBulkUpdate($hash, "station_" . $i . "_lastRun", "keine Daten");
                                    }
                                }
                            }
                        }
                    }
                    my $nstations = $json->{status};
                    readingsBulkUpdate($hash, "total_stations", $nstations->{nstations}) if exists $nstations->{nstations};
                    readingsBulkUpdate($hash, "state", "connected");
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
