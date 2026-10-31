#!/usr/bin/env python3
"""Fetch recent headlines for the HomeBlocks news desks.

Source: Wikipedia's Current Events portal (one page per day, CC BY-SA 4.0). Keeps only lighter categories
(arts and culture, business, health and environment, science and technology, sports) and drops anything about
deaths, violence, disasters, crime, courts, war or elections, so residents never react cheerfully to a tragedy or
to real politicians. Writes news.json next to index.html; the pages read it at run time.

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
    if not out:
        print('no items; keeping the old news.json', file=sys.stderr); return
    out.sort(key=lambda x: x['d'], reverse=True)
    doc = {'source': 'Wikipedia, Portal:Current events', 'license': 'CC BY-SA 4.0',
           'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/', 'portal': 'https://en.wikipedia.org/wiki/Portal:Current_events',
           'items': out}
    with open('news.json', 'w') as f:
        json.dump(doc, f, ensure_ascii=False, indent=0)
    print(len(out), 'items over', len(per), 'days', file=sys.stderr)


if __name__ == '__main__':
    main()
