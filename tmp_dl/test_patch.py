import re
s = open('main.cpp', encoding='utf-8').read()
pat = r'^(?P<ind>[ \t]*)SDL_Quit\(\);\s*$'
ms = list(re.finditer(pat, s, re.M))
print('matches:', len(ms))
for m in ms:
    ln = s[:m.start()].count('\n') + 1
    print('  line', ln, 'indent=', repr(m.group('ind')))
def _wrap(m):
    ind = m.group('ind')
    return ('#if defined(__APPLE__)\n' + ind +
            'dispatch_sync(dispatch_get_main_queue(), ^{\n' + ind +
            '    SDL_Quit();\n' + ind + '});\n' + '#else\n' + ind +
            'SDL_Quit();\n' + '#endif\n')
s2 = re.sub(pat, _wrap, s, flags=re.M)
left = re.search(r'^\s*SDL_Quit\(\);\s*$', s2, re.M)
print('after-sub bare SDL_Quit on own line remains?', bool(left))
