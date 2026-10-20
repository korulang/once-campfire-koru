import sys, collections, re, os
# tools/allocs/report.py OUT [DEPTH] [TOP]: allocshim's output as calls and bytes per response, by
# library and by the nearest frames of the app. Ported from lucasmeijer/once-campfire-jai; app
# frames are matched by our binary's basename (APP_BIN or a.out), not his `campfire`.
path = sys.argv[1]; depth = int(sys.argv[2]) if len(sys.argv) > 2 else 3; top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
lines = open(path).read().split('\n')
head = {}
for l in lines[:7]:
    p = l.split()
    if p and p[0] in ('writes','bytes','sample'): head[p[0]] = int(p[1])
    if p and p[0] == 'count': head[p[1]] = int(p[2])
writes, sample = head['writes'], head['sample']
# The writev counter assumes one syscall per response — flat single-segment
# sends go through write() and partial sends count twice. The loadgen's valid
# count is the denominator that can't lie; fall back to writev only if the
# loadgen JSON is absent.
responses, source = writes, "writev"
rj = os.environ.get("RESPONSES_JSON")
if rj and os.path.exists(rj):
    import json
    try:
        d = json.load(open(rj))
        n = d.get("ok") or 0
        if n: responses, source = n, "loadgen.ok"
    except Exception:
        pass
writes = responses
APP_DSO = os.path.basename(os.environ.get("APP_BIN", "a.out"))
GENERIC = re.compile(r'^(alloc|free|heap_alloc|heap_free|allocator_proc|default_allocator_proc|realloc|New|copy_string|alloc_string|'
    r'array_reserve|array_add|maybe_grow|sprint|tprint|builder_to_string|array_copy|array_free|table_add|table_set|resize|init|deinit|'
    r'expand|join|split|get_new_buffer|append|copy|reserve|grow|CRYPTO_\w+|OPENSSL_\w+|EVP_\w+|HMAC\w*|sqlite3\w*Malloc\w*|'
    r'sqlite3Realloc|sqlite3DbRealloc|sqlite3_free|sqlite3_malloc\w*|measure\w*|yyjson_\w*alloc\w*|zcalloc|zcfree|default_\w+|\?)$')
SKIP = {'entry_proc','worker_thread','run_job','front_response','cached_response','proxy','handle_request','run_action',
    'guarded_dispatch','run_guarded','run','event_loop_thread','dispatch'}
sites = collections.Counter(); site_bytes = collections.Counter(); libs = collections.Counter()
sampled = collections.Counter(l.split()[1] for l in lines if l.startswith('S '))
# Samples stop at the shim's cap: scale each kind by what was counted over what was sampled.
scale_of = {k: head[k] / sampled[k] for k in sampled}
sampled_mallocs = sampled['malloc'] + sampled['calloc']
scale_of['malloc'] = (head['malloc'] + head['calloc']) / sampled_mallocs if sampled_mallocs else 0
for l in lines:
    if not l.startswith('S '): continue
    p = l.split()
    kind, size, frames = p[1], int(p[2]), p[3:]
    names = []
    lib = None
    for f in frames[1:]:
        dso, _, name = f.partition(':')
        name = re.sub(r'_[0-9a-f]{9,}$', '', name)
        if lib is None and dso not in ('libc.so.6',):
            if dso.startswith('libcrypto') or dso.startswith('libssl'): lib = 'openssl'
            elif dso.startswith('libcurl'): lib = 'curl'
            elif dso.startswith('libz'): lib = 'zlib'
            elif name.startswith(('sqlite3','pcache','fts5')) or name == '?': lib = 'C (sqlite/gumbo/yyjson)' if name == '?' else 'sqlite'
            else: lib = 'app'
        if dso == APP_DSO and not GENERIC.match(name) and name not in SKIP: names.append(name)
    key = (kind if kind != 'calloc' else 'malloc', lib or '?', ' < '.join(names[:depth]) or '?')
    scale = scale_of['malloc' if kind == 'calloc' else kind]
    sites[key] += scale; site_bytes[key] += size * scale
    libs[(key[0], key[1])] += scale
print(f"responses {writes} ({source}; writev saw {head['writes']}); per response: malloc {head['malloc']/writes:.1f}, calloc {head['calloc']/writes:.2f}, realloc {head['realloc']/writes:.1f}, free {head['free']/writes:.1f}, bytes {head['bytes']/writes:,.0f}")
print("by library (calls/response):")
for (k, lib), n in sorted(libs.items(), key=lambda x: -x[1]): print(f"  {k:7s} {lib:24s} {n/writes:7.2f}")
print("top sites (calls/response, bytes/response):")
for key, n in sites.most_common(top):
    print(f"  {n/writes:7.2f} {site_bytes[key]/writes:10,.0f}  {key[0]:7s} {key[1]:10s} {key[2][:150]}")
print("top sites by bytes:")
for key, b in site_bytes.most_common(12):
    print(f"  {sites[key]/writes:7.2f} {b/writes:10,.0f}  {key[0]:7s} {key[1]:10s} {key[2][:150]}")
