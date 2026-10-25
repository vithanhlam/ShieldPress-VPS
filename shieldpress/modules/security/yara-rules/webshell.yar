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

rule SP_PHP_Indirect_Encoded_Execution : suspicious php {
    meta:
        description = "PHP executes a variable alongside an encoded payload decoder"
    strings:
        $php = "<?php" nocase
        $eval = /eval[ \t\r\n]*\([ \t\r\n]*\$/ nocase
        $decode = /(base64_decode|gzinflate|gzuncompress|str_rot13)[ \t\r\n]*\(/ nocase
        $dynamic_decode = "bas e64 _de cod e" nocase
    condition:
        $php and $eval and ($decode or $dynamic_decode)
}

rule SP_PHP_Remote_Code_Execution : suspicious php {
    meta:
        description = "PHP fetches code over HTTP and executes a variable"
    strings:
        $php = "<?php" nocase
        $fetch = /file_get_contents[ \t\r\n]*\(/ nocase
        $remote = /https?:\/\// nocase
        $eval = /eval[ \t\r\n]*\([ \t\r\n]*\$/ nocase
    condition:
        $php and all of ($fetch, $remote, $eval)
}

rule SP_PHP_Appended_Payload_Loader : suspicious php {
    meta:
        description = "PHP decompresses an appended binary payload into executable temporary code"
    strings:
        $php = "<?php" nocase
        $halt = "__halt_compiler" nocase
        $offset = "__COMPILER_HALT_OFFSET__"
        $inflate = "gzinflate" nocase
        $temp = "tmpfile" nocase
        $load = /include[ \t\r\n]+/ nocase
    condition:
        $php and all of ($halt, $offset, $inflate, $temp, $load)
}

rule SP_PHP_Session_Payload_Execution : suspicious php {
    meta:
        description = "PHP stages request data in a session and executes decoded payloads"
    strings:
        $php = "<?php" nocase
        $post = "$_POST"
        $session = "$_SESSION"
        $decode = "base64_decode" nocase
        $eval = /eval[ \t\r\n]*\(/ nocase
    condition:
        $php and all of ($post, $session, $decode, $eval)
}
