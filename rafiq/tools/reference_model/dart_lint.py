"""Poor man's Dart sanity check: lexical errors + balanced brackets + statement hygiene."""
import sys, re
from pygments.lexers import DartLexer
from pygments.token import Token

def check(path):
    src = open(path, encoding='utf-8').read()
    toks = list(DartLexer().get_tokens(src))
    problems = []
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    line = 1
    for ttype, val in toks:
        if ttype in Token.Error:
            problems.append(f'lexical error near line {line}: {val!r}')
        if ttype in Token.Punctuation or ttype in Token.Operator:
            for ch in val:
                if ch in '([{':
                    stack.append((ch, line))
                elif ch in ')]}':
                    if not stack or stack[-1][0] != pairs[ch]:
                        problems.append(f'unbalanced {ch} at line {line}')
                    else:
                        stack.pop()
        line += val.count('\n')
    for ch, ln in stack:
        problems.append(f'unclosed {ch} from line {ln}')
    # heuristic: a line that ends an expression statement without ; or { or , etc.
    for n, l in enumerate(src.splitlines(), 1):
        s = l.strip()
        if not s or s.startswith('//') or s.startswith('///') or s.startswith('*'):
            continue
        if re.match(r"^(final|const|int|double|bool|String|var|List<|Map<|Set<)[^=;{(]*=[^;]*$", s) and not s.endswith((',', '(', '[', '{', '?', ':', '&&', '||', '+', '-', '=>', '=')):
            problems.append(f'line {n}: declaration without terminator? {s[:70]}')
    return problems

for p in sys.argv[1:]:
    pr = check(p)
    print(p, '->', 'OK' if not pr else '')
    for x in pr: print('   ', x)
