#!/usr/bin/env python3
"""Fetch recent headlines for the HomeBlocks news desks.

Source: Wikipedia's Current Events portal (one page per day, CC BY-SA 4.0). Keeps only lighter categories
(arts and culture, business, health and environment, science and technology, sports) and drops anything about
deaths, violence, disasters, crime, courts, war or elections, so residents never react cheerfully to a tragedy or
to real politicians. Writes news.json next to index.html; the pages read it at run time.

Also writes a "local scene" beat from public, aggregate numbers only: megaZINE's issues (works.json) and visit
counts (stats/stats.json), and the MEGAzine BBS's board totals (its /api/info: users, callers, files, posts). A
daily history of the BBS totals is kept in news.json so the desks can report what changed and when the board
passes a milestone. No caller names, messages or anything private.

Usage: python3 tools/news.py [days]   (default 21)
"""
import html, json, re, sys, time, urllib.parse, urllib.request
from datetime import date, timedelta
from html.parser import HTMLParser

UA = 'BigAppleSam-HomeBlocks/1.0 (https://samuelling.github.io/Big-Apple-Sam/; news desk headlines)'
KEEP = {'Arts and culture': 'culture', 'Business and economy': 'business', 'Health and environment': 'environment',
        'Science and technology': 'science', 'Sports': 'sports'}
SKIP = re.compile(r'\b(kill|killed|killing|dies|died|death|deaths|dead|fatal|injur\w*|attack\w*|shoot\w*|shot|bomb\w*|explosion|crash\w*|'
                  r'victim\w*|earthquake|flood\w*|hurricane|typhoon|cyclone|wildfire|fire|tsunami|kidnap\w*|terror\w*|missile|war|wars|'
                  r'military|troops|army|airstrike|protest\w*|riot\w*|court|courts|judge|lawsuit|sue[sd]?|sentenc\w*|arrest\w*|charged|'
                  r'convict\w*|prison|jail\w*|police|crime|criminal|election\w*|elect\w*|president|prime minister|minister|senator|'
                  r'congress\w*|parliament\w*|government|governor|tariff\w*|sanction\w*|outbreak|epidemic|pandemic|virus|infect\w*|cases|'
                  r'abuse|assault|suicide|overdose|famine|refugee\w*|migrant\w*|deport\w*|hostage\w*|genocide|scandal|resign\w*|authorit\w*|'
                  r'boycott\w*|withdraw\w*|censor\w*|regime|kremlin|israel\w*|gaza|palestin\w*|ukrain\w*|russia\w*|hamas|hezbollah|'
                  r'conflict\w*|security concerns|litigation\w*|wildfire\w*|drought\w*|doping|bans?|banned)\b', re.I)


class Day(HTMLParser):
    """Walks a month's portal page: each day starts with a hidden <span class="bday">YYYY-MM-DD</span>, then
    <p><b>Category</b></p> and nested lists; the innermost items are the news."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.day = None; self.in_day = False
        self.cat = None; self.in_b = False; self.btext = ''
        self.stack = []          # one entry per open <li>: {'text': str, 'kids': bool, 'link': str|None, 'src': int}
        self.items = []; self.depth_a = 0; self.ext = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'span' and 'bday' in (a.get('class') or ''): self.in_day = True; self.cat = None
        elif tag == 'b' and not self.stack: self.in_b = True; self.btext = ''
        elif tag == 'ul' and self.stack: self.stack[-1]['kids'] = True
        elif tag == 'li': self.stack.append({'text': '', 'kids': False, 'link': None})
        elif tag == 'a' and self.stack:
            href = a.get('href', '')
            self.ext = 'external' in a.get('class', '')
            if not self.ext and href.startswith('/wiki/') and not self.stack[-1]['link'] and not self.stack[-1]['kids']:
                self.stack[-1]['link'] = 'https://en.wikipedia.org' + href
        elif tag in ('sup', 'style'): self.depth_a += 1

    def handle_endtag(self, tag):
        if tag == 'b' and self.in_b:
            self.in_b = False; t = self.btext.strip()
            if t: self.cat = t
        elif tag == 'li' and self.stack:
            li = self.stack.pop()
            if not li['kids'] and self.cat in KEEP:
                text = re.sub(r'\s+', ' ', li['text']).strip()
                topic = re.sub(r'\s+', ' ', self.stack[0]['text']).strip() if self.stack else ''
                if text and len(text) > 30 and not SKIP.search(text) and not SKIP.search(topic):
                    self.items.append({'d': self.day, 'cat': KEEP[self.cat], 'topic': topic[:80], 'text': text[:420], 'link': li['link']})
        elif tag == 'a': self.ext = False
        elif tag in ('sup', 'style'): self.depth_a = max(0, self.depth_a - 1)

    def handle_data(self, data):
        if self.in_day:
            if re.match(r'\d{4}-\d\d-\d\d', data.strip()): self.day = data.strip()
            self.in_day = False
        elif self.in_b: self.btext += data
        elif self.stack and not self.ext and not self.depth_a and not self.stack[-1]['kids']:
            self.stack[-1]['text'] += data


def fetch(title):
    url = 'https://en.wikipedia.org/w/api.php?' + urllib.parse.urlencode(
        {'action': 'parse', 'page': title, 'prop': 'text', 'format': 'json', 'formatversion': 2})
    for k in range(6):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': UA}), timeout=60) as r:
                body = r.read().decode('utf-8')
            if body.lstrip().startswith('{'):
                return json.loads(body).get('parse', {}).get('text')
        except Exception as e:
            print('  retry', title, e, file=sys.stderr)
        time.sleep(10 + 15 * k)
    return None


def get_json(url, body=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={'User-Agent': UA, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8'))
    except Exception as e:
        print('  could not read', url, e, file=sys.stderr); return None


def scene(old, today):
    """The local beat: megaZINE issues and readership, and the BBS's board totals, with a daily history."""
    t = today.isoformat(); prev = (old or {}).get('scene') or {}
    if prev.get('day') == t:
        return prev                      # once a day is plenty
    hist = [h for h in prev.get('history', []) if h.get('d') != t][-120:]
    miles = prev.get('milestones', [])[-30:]
    items = []
    works = get_json('https://megazine.org/works.json')
    stats = get_json('https://megazine.org/stats/stats.json')
    bbs = get_json('https://bbs.samuelling.workers.dev/api/info', {})
    if works:
        byid = {w['id']: w for w in works.get('works', [])}
        for iss in works.get('issues', []):
            m = iss.get('month') or ''
            if iss.get('draft') or not iss.get('works') or m > t[:7]: continue
            ws = [byid[i] for i in iss['works'] if i in byid and not byid[i].get('hidden')]
            names = [w['title'] for w in ws[:3]]
            items.append({'d': m + '-01', 'cat': 'local', 'src': 'zine', 'topic': f"megaZINE Issue {iss['id']}",
                          'text': f"megaZINE Issue {iss['id']} is out: one sheet of paper folded into an 8-page mini-zine, with {len(ws)} pieces"
                                  + (f", including {', '.join(names[:-1])} and {names[-1]}" if len(names) > 1 else '') + '.',
                          'link': f"https://megazine.org/?issue={iss['id']}"})
        if stats:
            days = stats.get('days', {})
            wk = sum(v for k, v in days.items() if k > (today - timedelta(days=7)).isoformat())
            if wk:
                items.append({'d': t, 'cat': 'local', 'src': 'zine', 'topic': 'megaZINE readership',
                              'text': f"megaZINE's website had {wk} visits in the past week.", 'link': 'https://megazine.org/'})
            clicks = []
            for p in stats.get('paths', []):
                if p.get('path', '').startswith('click/') and p['path'][6:] in byid:
                    n = sum(v for k, v in (p.get('days') or {}).items() if k > (today - timedelta(days=14)).isoformat())
                    if n: clicks.append((n, p['path'][6:]))
            if clicks:
                n, wid = max(clicks)
                items.append({'d': t, 'cat': 'local', 'src': 'zine', 'topic': 'megaZINE\'s most popular piece',
                              'text': f"The most-clicked piece in megaZINE over the past two weeks is {byid[wid]['title']}, with {n} clicks.",
                              'link': f'https://megazine.org/?go={wid}'})
    if bbs and 'callers' in bbs:
        snap = {'d': t, 'users': bbs.get('users', 0), 'callers': bbs.get('callers', 0), 'files': bbs.get('files', 0),
                'posts': bbs.get('posts', 0), 'bytes': bbs.get('bytes', 0), 'lines': bbs.get('lines', 1)}
        last = hist[-1] if hist else None
        for m in (10, 25, 50, 100, 250, 500, 1000, 2500, 5000):
            if last and last['callers'] < m <= snap['callers']:
                miles.append({'d': t, 'text': f"The MEGAzine BBS passed {m} callers."})
        hist.append(snap)
        week = next((h for h in reversed(hist) if h['d'] <= (today - timedelta(days=7)).isoformat()), None)
        gb = snap['bytes'] / 1e9
        txt = (f"The MEGAzine BBS has had {snap['callers']} callers so far. It has {snap['users']} users, {snap['files']} files "
               f"({gb:.1f} GB) in its file areas and {snap['lines']} phone line{'s' if snap['lines'] != 1 else ''}; when they're all busy, callers get a busy signal.")
        if week:
            dc, du, df = snap['callers'] - week['callers'], snap['users'] - week['users'], snap['files'] - week['files']
            bits = [f"{dc} new caller{'s' if dc != 1 else ''}" if dc > 0 else '', f"{du} new user{'s' if du != 1 else ''}" if du > 0 else '',
                    f"{df} new file{'s' if df != 1 else ''}" if df > 0 else '']
            bits = [b for b in bits if b]
            if bits: txt += ' This week: ' + ', '.join(bits) + '.'
        items.append({'d': t, 'cat': 'local', 'src': 'bbs', 'topic': 'MEGAzine BBS', 'text': txt, 'link': 'https://samuelling.github.io/BBS/'})
    for m in miles:
        items.append({'d': m['d'], 'cat': 'local', 'src': 'bbs', 'topic': 'MEGAzine BBS milestone', 'text': m['text'], 'link': 'https://samuelling.github.io/BBS/'})
    return {'day': t, 'history': hist, 'milestones': miles, 'items': items}


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 21
    today = date.today(); first = today - timedelta(days=days - 1)
    months = sorted({(d.year, d.month) for d in (first + timedelta(n) for n in range(days))})
    items = []
    for y, m in months:
        h = fetch(f'Portal:Current_events/{date(y, m, 1).strftime("%B")}_{y}')
        if not h:
            print('could not fetch', y, m, file=sys.stderr); continue
        p = Day(); p.feed(h); items += p.items
        time.sleep(3)
    per, seen, out = {}, set(), []
    for it in items:
        if not it['d'] or it['d'] < first.isoformat() or it['d'] > today.isoformat() or it['text'] in seen: continue
        if per.get(it['d'], 0) >= 14: continue
        seen.add(it['text']); per[it['d']] = per.get(it['d'], 0) + 1; out.append(it)
    try:
        old = json.load(open('news.json'))
    except Exception:
        old = None
    if not out:
        print('no wire items; keeping the old ones', file=sys.stderr)
        out = [i for i in (old or {}).get('items', []) if i.get('cat') != 'local']
    sc = scene(old, today)
    out = [i for i in out if i.get('cat') != 'local'] + [i for i in sc['items'] if i['d'] >= first.isoformat() or i.get('src') == 'zine']
    out.sort(key=lambda x: x['d'], reverse=True)
    doc = {'scene': sc, 'source': 'Wikipedia, Portal:Current events', 'license': 'CC BY-SA 4.0',
           'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/', 'portal': 'https://en.wikipedia.org/wiki/Portal:Current_events',
           'items': out}
    with open('news.json', 'w') as f:
        json.dump(doc, f, ensure_ascii=False, indent=0)
    print(len(out), 'items over', len(per), 'days', file=sys.stderr)


if __name__ == '__main__':
    main()
