// Conservative starter rules, maintained with ShieldPress releases.
// Matches are review findings, not proof that a file is malicious.
rule SP_PHP_Encoded_Execution : suspicious php {
    meta:
        description = "PHP code combines eval execution with encoded payload decoding"
    strings:
        $php = "<?php" nocase
        $exec = /eval[ \t\r\n]*\([ \t\r\n]*(base64_decode|gzinflate|gzuncompress|str_rot13)[ \t\r\n]*\(/ nocase
    condition:
        $php and $exec
}

rule SP_PHP_Request_Command : suspicious php {
    meta:
        description = "PHP directly passes request input to a command execution function"
    strings:
        $php = "<?php" nocase
        $exec = /(system|shell_exec|passthru|exec)[ \t\r\n]*\([ \t\r\n]*\$_(GET|POST|REQUEST|COOKIE)[ \t\r\n]*\[/ nocase
    condition:
        $php and $exec
}

rule SP_EICAR_Test_File : test {
    meta:
        description = "Harmless EICAR antivirus test marker"
    strings:
        $marker = "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!"
    condition:
        $marker
}
