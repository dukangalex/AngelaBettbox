#!/usr/bin/env python3
"""Write Android signing properties from the CI environment without logging values."""
import os
from pathlib import Path

def escape(value):
    result = ''
    for char in value:
        if char in '\\:=#! ': result += '\\' + char
        elif char == '\n': result += '\\n'
        elif char == '\r': result += '\\r'
        elif char == '\t': result += '\\t'
        elif ord(char) > 127:
            encoded = char.encode('utf-16-be')
            result += ''.join('\\u' + encoded[i:i+2].hex() for i in range(0,len(encoded),2))
        else: result += char
    return result

if __name__ == '__main__':
    pairs = {'keyAlias':'KEY_ALIAS', 'storePassword':'STORE_PASSWORD', 'keyPassword':'KEY_PASSWORD'}
    with Path('android/local.properties').open('a', encoding='ascii') as out:
        out.write('\n')
        for prop, env in pairs.items():
            out.write(prop + '=' + escape(os.environ[env]) + '\n')
