#!/usr/bin/env python3
"""Add a password-file option to the pinned zsign CLI.

Upstream's -p takes the password as argv, visible in process listings while
signing. XForge adds -Q/--password_file: zsign reads it into its private string,
then the caller can unlink the file. This patch is applied only to the verified,
pinned upstream source tree during the one-time guest build.
"""
from pathlib import Path

p = Path("src/zsign.cpp")
s = p.read_text()

old_opt = '\t{"password", required_argument, NULL, \'p\'},'
new_opt = old_opt + '\n\t{"password_file", required_argument, NULL, \'Q\'},'
assert old_opt in s, "pinned zsign option table changed; review the patch"
s = s.replace(old_opt, new_opt, 1)

old_flags = '"dfva2LhiqwCRSEWUPc:k:m:o:p:e:b:n:z:l:D:t:r:x:M:I:"'
new_flags = '"dfva2LhiqwCRSEWUPc:k:m:o:p:Q:e:b:n:z:l:D:t:r:x:M:I:"'
assert old_flags in s, "pinned zsign getopt string changed; review the patch"
s = s.replace(old_flags, new_flags, 1)

old_case = "\t\tcase 'p':\n\t\t\tstrPassword = optarg;\n\t\t\tbreak;"
new_case = old_case + "\n\t\tcase 'Q':\n\t\t\tif (!ZFile::ReadFile(optarg, strPassword)) {\n\t\t\t\tZLog::ErrorV(\">>> Failed to read password file! %s\\n\", optarg);\n\t\t\t\treturn -1;\n\t\t\t}\n\t\t\twhile (!strPassword.empty() && (strPassword.back() == '\\n' || strPassword.back() == '\\r')) strPassword.pop_back();\n\t\t\tbreak;"
assert old_case in s, "pinned zsign password switch changed; review the patch"
s = s.replace(old_case, new_case, 1)
p.write_text(s)

# This pinned upstream snapshot's Linux Makefile exposes a separate header bug:
# json.h uses time_t but never includes the header that defines it. Some host
# toolchains happen to include it transitively; musl/Alpine's does not. Make the
# dependency explicit so the guest build is deterministic.
p = Path("src/common/json.h")
s = p.read_text()
include = "#include <string>"
assert include in s, "pinned zsign JSON header layout changed; review the patch"
if "#include <ctime>" not in s and "#include <time.h>" not in s:
    s = s.replace(include, "#include <ctime>\n" + include, 1)
p.write_text(s)
