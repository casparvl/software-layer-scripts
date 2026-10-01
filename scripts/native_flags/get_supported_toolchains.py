#!/usr/bin/env python3
#
# Print the top-level toolchains supported in a given EESSI version, one 'name/version' per line.
#
# The list is extracted from EESSI_SUPPORTED_TOP_LEVEL_TOOLCHAINS in eb_hooks.py (so there is a single source of
# truth), without importing eb_hooks.py itself (which would require EasyBuild to be available).
# Conditional additions like 'EESSI_SUPPORTED_TOP_LEVEL_TOOLCHAINS[<version>].append({...})' are included
# regardless of the condition they are guarded by (those conditions are on the EasyBuild version, which is
# irrelevant for determining which compilers are part of an EESSI version).
# Site-specific toplevel toolchains defined via $EESSI_SITE_TOP_LEVEL_TOOLCHAINS_<version> are included as well,
# in the same way as is done in eb_hooks.py.
#
# usage: get_supported_toolchains.py <path to eb_hooks.py> <EESSI version>

import ast
import json
import os
import sys

TOOLCHAINS_VAR = 'EESSI_SUPPORTED_TOP_LEVEL_TOOLCHAINS'


def get_toolchains(hooks_file, eessi_version):
    with open(hooks_file) as fh:
        tree = ast.parse(fh.read(), filename=hooks_file)

    toolchains = None
    appended = []
    for node in ast.walk(tree):
        # EESSI_SUPPORTED_TOP_LEVEL_TOOLCHAINS = {...}
        if isinstance(node, ast.Assign) and any(getattr(t, 'id', None) == TOOLCHAINS_VAR for t in node.targets):
            toolchains = ast.literal_eval(node.value)
        # EESSI_SUPPORTED_TOP_LEVEL_TOOLCHAINS['<version>'].append({...})
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'append'
              and isinstance(node.func.value, ast.Subscript)
              and getattr(node.func.value.value, 'id', None) == TOOLCHAINS_VAR):
            subscript = node.func.value.slice
            # Python < 3.9 wraps the subscript in an ast.Index node
            subscript = getattr(subscript, 'value', subscript) if type(subscript).__name__ == 'Index' else subscript
            version = ast.literal_eval(subscript)
            appended.append((version, ast.literal_eval(node.args[0])))

    if toolchains is None:
        sys.stderr.write(f"ERROR: failed to find {TOOLCHAINS_VAR} in {hooks_file}\n")
        sys.exit(1)
    if eessi_version not in toolchains:
        sys.stderr.write(f"ERROR: no supported toolchains defined for EESSI version {eessi_version} in {hooks_file}\n")
        sys.exit(1)

    result = list(toolchains[eessi_version])
    result.extend(tc for (version, tc) in appended if version == eessi_version)

    site_var = 'EESSI_SITE_TOP_LEVEL_TOOLCHAINS_' + eessi_version.replace('.', '_')
    if os.getenv(site_var):
        result.extend(json.loads(os.getenv(site_var)))

    return result


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <path to eb_hooks.py> <EESSI version>\n")
        sys.exit(1)

    seen = set()
    for tc in get_toolchains(sys.argv[1], sys.argv[2]):
        tc_mod = f"{tc['name']}/{tc['version']}"
        if tc_mod not in seen:
            seen.add(tc_mod)
            print(tc_mod)


if __name__ == '__main__':
    main()
