###############################################################################
# $Id: 73_OpenSprinkler.pm 2026-06-12 12:15:00Z ModdedByAI $
#
# FHEM Modul zur Einbindung von OpenSprinkler
# Überarbeitet für sichere Passwortspeicherung im FHEM-Keyring
# Inklusive Echtzeit-Polls nach Schaltvorgängen und Passworteingabe
#
###############################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use Digest::MD5 qw(md5_hex);

# Vorwärtsdeklarationen für FHEM-Konformität
sub OpenSprinkler_Initialize($);
sub OpenSprinkler_Define($$);
sub OpenSprinkler_Undefine($$);
sub OpenSprinkler_Set($@);
sub OpenSprinkler_Poll($);

sub OpenSprinkler_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = "OpenSprinkler_Define";
    $hash->{UndefFn}  = "OpenSprinkler_Undefine";
    $hash->{SetFn}    = "OpenSprinkler_Set";
    $hash->{AttrList} = "interval " . $readingFnAttributes;
    
    return undef;
}

sub OpenSprinkler_Define($$) {
    my ($hash, $def) = @_;
    my @a = split("[ \t]+", $def);

    # Prüfung auf korrekte Anzahl an Argumenten (mindestens Name, Typ, IP)
    if (int(@a) < 3) {
        return "Too few arguments. Usage: define <name> OpenSprinkler <IP-Adresse>";
    }

    my $name = $a;
    my $ip   = $a;

    $hash->{NAME} = $name;
    $hash->{IP}   = $ip;

    # Intervall für Abfragen festlegen (Standard: 60 Sekunden)
    $attr{$name}{interval} = 60 if (!defined($attr{$name}{interval}));

    # Sicheres Auslesen aus dem Keyring (FHEM API konform mit großem V)
    my ($key_err, $stored_pw) = getKeyValue($name . "_password");
    
    if (!defined($key_err) && defined($stored_pw) && $stored_pw ne "") {
        $hash->{PW} = md5_hex($stored_pw);
        Log3 $name, 3, "OpenSprinkler ($name): Passwort erfolgreich aus Keyring geladen.";
    } else {
        Log3 $name, 1, "OpenSprinkler ($name): WARNUNG - Kein Passwort hinterlegt! Bitte mit 'set $name password <dein_passwort>' setzen.";
    }

    # Timer für zyklische Datenabfragen starten
    RemoveInternalTimer($hash);
    InternalTimer(time() + 1, "OpenSprinkler_Poll", $hash);

    return undef;
}

sub OpenSprinkler_Undefine($$) {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

sub OpenSprinkler_Set($@) {
    my ($hash, @a) = @_;
    my $name = $a;
    my $cmd  = $a;
    my $args = $a;

    # Hilfetext für das FHEM-Frontend
    my $help = "Unknown argument $cmd, choose one of password rainDelay system_enabled:on,off station_0_start station_0_stop station_1_start station_1_stop station_2_start station_2_stop station_3_start station_3_stop station_4_start station_4_stop station_5_start station_5_stop station_6_start station_6_stop station_7_start station_7_stop";

    # Wenn FHEMWEB nur die Befehlsliste abfragt
    return $help if (!defined($cmd) || $cmd eq "?");

    # 1. Passwort sicher setzen
    if ($cmd eq "password") {
        if (!defined($args) || $args eq "") {
            return "Usage: set $name password <cleartext_password>";
        }
        
        # Aufruf von setKeyValue (großes V)
        eval {
            setKeyValue($name . "_password", $args);
        };
        if ($@) {
            return "Fehler beim Speichern im Keyring: $@";
        }
        
        $hash->{PW} = md5_hex($args);
        Log3 $name, 3, "OpenSprinkler ($name): Passwort wurde im FHEM-Keyring gesichert.";
        
        # ERWEITERUNG: Sofortigen Datenabruf nach Passworteingabe erzwingen
        RemoveInternalTimer($hash);
        InternalTimer(time() + 0.1, "OpenSprinkler_Poll", $hash);
        
        return undef; 
    }

    # 2. Sicherheitsprüfung für alle funktionalen Steuerbefehle
    if (!defined($hash->{PW})) {
        return "Error: Kein Passwort gesetzt. Bitte führen Sie zuerst 'set $name password <passwort>' aus.";
    }

    # STATION STARTEN
    if ($cmd =~ /^station_([0-7])_start$/) {
        if (!defined($args) || $args !~ /^\d+$/) {
            return "Usage: set $name $cmd <seconds>";
        }
        my $station = $1;
        my $url = "http://" . $hash->{IP} . "/cm?pw=" . $hash->{PW} . "&sid=" . $station . "&t=" . $args;
        HttpUtils_NonblockingGet({
            url     => $url,
            timeout => 5,
            hash    => $hash,
            callback=> sub { 
                Log3 $name, 4, "OpenSprinkler ($name): Station $station gestartet ($args Sek).";
                # ERWEITERUNG: Sofortiges Auslesen der neuen Zustände erzwingen
                RemoveInternalTimer($hash);
                InternalTimer(time() + 0.5, "OpenSprinkler_Poll", $hash);
            }
        });
        return undef;
    }

    # STATION STOPPEN
    elsif ($cmd =~ /^station_([0-7])_stop$/) {
        my $station = $1;
        my $url = "http://" . $hash->{IP} . "/cm?pw=" . $hash->{PW} . "&sid=" . $station . "&t=0";
        HttpUtils_NonblockingGet({
            url     => $url,
            timeout => 5,
            hash    => $hash,
            callback=> sub { 
                Log3 $name, 4, "OpenSprinkler ($name): Station $station manuell gestoppt.";
                # ERWEITERUNG: Sofortiges Auslesen der neuen Zustände erzwingen
                RemoveInternalTimer($hash);
                InternalTimer(time() + 0.5, "OpenSprinkler_Poll", $hash);
            }
        });
        return undef;
    }

    # GLOBALE REGEN-VERZÖGERUNG
    elsif ($cmd eq "rainDelay") {
        if (!defined($args) || $args !~ /^\d+$/) {
            return "Usage: set $name rainDelay <hours>";
        }
        my $url = "http://" . $hash->{IP} . "/cv?pw=" . $hash->{PW} . "&rd=" . $args;
        HttpUtils_NonblockingGet({
            url     => $url,
            timeout => 5,
            hash    => $hash,
            callback=> sub { 
                Log3 $name, 4, "OpenSprinkler ($name): Regen-Verzögerung auf $args Stunden gesetzt.";
                # ERWEITERUNG: Sofortiges Auslesen der neuen Zustände erzwingen
                RemoveInternalTimer($hash);
                InternalTimer(time() + 0.5, "OpenSprinkler_Poll", $hash);
            }
        });
        return undef;
    }

    # SYSTEM-BETRIEB
    elsif ($cmd eq "system_enabled") {
        if (!defined($args) || ($args ne "on" && $args ne "off")) {
            return "Usage: set $name system_enabled [on|off]";
        }
        my $val = ($args eq "on") ? 1 : 0;
        my $url = "http://" . $hash->{IP} . "/cv?pw=" . $hash->{PW} . "&en=" . $val;
        HttpUtils_NonblockingGet({
            url     => $url,
            timeout => 5,
            hash    => $hash,
            callback=> sub { 
                Log3 $name, 4, "OpenSprinkler ($name): System-Betrieb geändert auf $args.";
                # ERWEITERUNG: Sofortiges Auslesen der neuen Zustände erzwingen
                RemoveInternalTimer($hash);
                InternalTimer(time() + 0.5, "OpenSprinkler_Poll", $hash);
            }
        });
        return undef;
    }

    return $help;
}

sub OpenSprinkler_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if (!defined($hash->{PW})) {
        my $interval = AttrVal($name, "interval", 60);
        InternalTimer(time() + $interval, "OpenSprinkler_Poll", $hash);
        return undef;
    }

    my $url = "http://" . $hash->{IP} . "/ja?pw=" . $hash->{PW};

    HttpUtils_NonblockingGet({
        url     => $url,
        timeout => 5,
        hash    => $hash,
        callback=> sub {
            my ($param, $err, $data) = @_;
            if ($err) {
                Log3 $name, 2, "OpenSprinkler ($name): Fehler bei Abfrage: $err";
                readingsSingleUpdate($hash, "state", "error", 1);
            } elsif ($data) {
                eval {
                    my $json = decode_json($data);
                    readingsBeginUpdate($hash);
                    
                    if (exists $json->{settings}) {
                        my $s = $json->{settings};
                        my %types = (1=>"OSPi (Raspberry)", 2=>"OpenSprinkler AC", 3=>"OpenSprinkler DC", 4=>"OpenSprinkler Lane");
                        readingsBulkUpdate($hash, "hardware_type", $types{$s->{devtype} // 0} // "Unknown");
                        readingsBulkUpdate($hash, "water_level", $s->{wl}) if exists $s->{wl};
                        readingsBulkUpdate($hash, "rain_delay", $s->{rd}) if exists $s->{rd};
                        readingsBulkUpdate($hash, "sensor_rain", ($s->{rs} ? "rain" : "dry")) if exists $s->{rs};
                        readingsBulkUpdate($hash, "flow_total_clicks", $s->{flcto}) if exists $s->{flcto};
                    }
                    
                    if (exists $json->{status} && exists $json->{status}->{sn}) {
                        my $stations = $json->{status}->{sn};
                        for (my $i = 0; $i < 8; $i++) {
                            if (defined $stations->[$i]) {
                                readingsBulkUpdate($hash, "station_" . $i . "_state", ($stations->[$i] ? "on" : "off"));
                            }
                        }
                    }
                    
                    if (exists $json->{stations} && exists $json->{stations}->{snames}) {
                        my $names = $json->{stations}->{snames};
                        for (my $i = 0; $i < 8; $i++) {
                            if (defined $names->[$i]) {
                                readingsBulkUpdate($hash, "station_" . $i . "_name", $names->[$i]);
                            }
                        }
                    }
                    
                    readingsBulkUpdate($hash, "state", "connected");
                    readingsEndUpdate($hash, 1);
                };
                if ($@) {
                    Log3 $name, 2, "OpenSprinkler ($name): JSON Parsing-Fehler: $@";
                }
            }
        }
    });

    # Nächsten regulären Poll-Timer einplanen
    my $interval = AttrVal($name, "interval", 60);
    InternalTimer(time() + $interval, "OpenSprinkler_Poll", $hash);
    return undef;
}

1;
