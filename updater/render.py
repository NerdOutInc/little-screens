#!/usr/bin/env python3
"""Portable deterministic OG renderer. No server, account access, or upload."""
import argparse
import json
import math
import struct
import zlib
from datetime import datetime, timedelta, date, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Timed values require an explicit timezone offset')
    return result


def phase(now):
    return 'morning' if 5 <= now.hour < 12 else 'afternoon' if 12 <= now.hour < 17 else 'evening' if 17 <= now.hour < 21 else 'night'


def encode_png(image):
    image = image.convert('L')
    if image.size != (800, 480):
        raise ValueError('Expected exactly 800×480 pixels')
    values = bytes(min(3, (p + 42) // 85) for p in image.tobytes())
    raw = bytearray()
    for y in range(480):
        raw.append(0)
        for x in range(0, 800, 4):
            p = y * 800 + x
            raw.append((values[p] << 6) | (values[p+1] << 4) | (values[p+2] << 2) | values[p+3])
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 800, 480, 2, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    if len(png) > 90000:
        raise ValueError('Image exceeds the OG 90,000-byte limit')
    return png


def font(size, bold=False):
    return ImageFont.truetype(str(ROOT / 'fonts' / ('AtkinsonHyperlegible-Bold.ttf' if bold else 'AtkinsonHyperlegible-Regular.ttf')), size)


def wrap(value, size, width, bold=False, max_lines=2):
    f = font(size, bold)
    words = str(value).split()
    lines = []
    current = ''
    for word in words:
        trial = (current + ' ' + word).strip()
        if f.getlength(trial) <= width:
            current = trial
        else:
            if current:
                lines.append(current)
            # Long unbroken identifiers must never escape the reserved surface.
            while f.getlength(word) > width:
                split = 1
                while split < len(word) and f.getlength(word[:split+1]) <= width:
                    split += 1
                lines.append(word[:split])
                word = word[split:]
            current = word
    if current:
        lines.append(current)
    truncated = len(lines) > max_lines
    lines = lines[:max_lines]
    if truncated and lines:
        while lines[-1] and f.getlength(lines[-1] + '…') > width:
            lines[-1] = lines[-1][:-1]
        lines[-1] += '…'
    return lines, truncated


def compact_time(value):
    hour = value.hour % 12 or 12
    return str(hour) + (':' + str(value.minute).zfill(2) if value.minute else '') + ('a' if value.hour < 12 else 'p')


def events_for(snapshot, profile, now):
    rows = []
    seen = set()
    zone = now.tzinfo
    last_day = now.date() + timedelta(days=profile.get('lookahead_days', 7))
    for e in snapshot['agenda']['events']:
        identity = (e['calendar'], e['id'])
        if identity in seen:
            raise ValueError('Duplicate source event')
        seen.add(identity)
        if e.get('status') in ('cancelled', 'canceled') or e.get('response_status') == 'declined':
            continue
        if not isinstance(e.get('all_day'), bool):
            raise ValueError('Verify the all_day flag before rendering')
        if e['all_day']:
            start, end = date.fromisoformat(e['start']), date.fromisoformat(e['end'])
            if end <= start:
                raise ValueError('All-day end date must be exclusive and after start')
            for offset in range((end - start).days):
                day = start + timedelta(days=offset)
                if now.date() <= day < last_day:
                    rows.append((day, 0, '', 'ALL DAY', e))
        else:
            start, end = timestamp(e['start']).astimezone(zone), timestamp(e['end']).astimezone(zone)
            if end <= start:
                raise ValueError('Event end must follow start')
            if end <= now or start.date() >= last_day:
                continue
            day = max(start.date(), now.date())
            label = compact_time(start) + '-' + compact_time(end)
            days = (end.date() - start.date()).days
            if days:
                label += ' (+' + str(days) + 'd)'
            rows.append((day, 1, start.isoformat(), label, e))
    return sorted(rows, key=lambda r: (r[0], r[1], r[2], r[4]['title']))


def render_weather(payload, now=None):
    profile, w = payload['profile'], payload['snapshot']['weather']
    now = (now or datetime.now(timezone.utc)).astimezone(ZoneInfo(profile['timezone']))
    observed = timestamp(w['observed_at']).astimezone(now.tzinfo)
    if observed > now + timedelta(minutes=5):
        raise ValueError('Source timestamp cannot be in the future')
    image = Image.new('L', (800, 480), 255)
    draw = ImageDraw.Draw(image)
    def text(value, x, y, size, width, bold=False):
        lines, _ = wrap(value, size, width, bold, 1)
        if lines: draw.text((x, y), lines[0], font=font(size, bold), fill=0, anchor='lt')
    def n(value):
        if value is None: return '—'
        if not isinstance(value, (int, float)) or not math.isfinite(value): raise ValueError('Weather values must be finite numbers or null')
        return f'{value:g}'
    text('SUGGESTED LOCATION' if profile.get('location_inferred') else 'YOUR LOCAL WEATHER', 30, 23, 13, 700, True)
    text(profile['location'], 28, 50, 38, 735, True)
    text(now.strftime('%A, %B ') + str(now.day), 30, 102, 18, 700)
    draw.line((30, 137, 770, 137), fill=0, width=2)
    text(n(w.get('temperature')) + '°', 26, 162, 108, 350, True)
    text('F', 300, 244, 20, 30)
    text(w['condition'], 30, 297, 28, 338, True)
    text('H ' + n(w.get('high')) + '°   L ' + n(w.get('low')) + '°', 30, 346, 25, 338)
    draw.line((384, 160, 384, 387), fill=170)
    readings = [('WIND', w.get('wind_direction', '') + ' ' + n(w.get('wind_speed')) + ' mph'), ('PRECIP · ' + w['precipitation_period'].upper(), n(w.get('precipitation_chance')) + ('%' if w.get('precipitation_chance') is not None else '')), ('UV RIGHT NOW', n(w.get('uv_current')))]
    for index, (label, value) in enumerate(readings):
        y = 163 + index * 77
        text(label, 419, y, 13, 340, True)
        text(value, 418, y+23, 29, 340, True)
    draw.line((30, 407, 770, 407), fill=0)
    stale = (now-observed).total_seconds() > 5400 or w['forecast_date'] != now.date().isoformat()
    footer = ('STALE · ' if stale else '') + 'Weather ' + compact_time(observed)
    text(footer, 30, 420, 13, 740, stale)
    note = w.get('note') or ('Wrong city? Ask Codex to change it. This is your first little screen.' if profile.get('location_inferred') else 'Ask Codex to customize this screen. Make it yours.')
    text(note, 30, 450, 12, 740)
    return encode_png(image), {'template': 'weather-starter-v1', 'location_inferred': bool(profile.get('location_inferred'))}


def render(payload, now=None):
    if payload['profile'].get('template') == 'weather-starter-v1':
        return render_weather(payload, now)
    profile, snapshot, scene = payload['profile'], payload['snapshot'], payload['scene']
    if profile.get('template') != 'daily-companion-v2':
        raise ValueError('Supported renderer template: daily-companion-v2')
    now = (now or datetime.now(timezone.utc)).astimezone(ZoneInfo(profile['timezone']))
    if scene['date'] != now.date().isoformat() or scene['phase'] != phase(now) or scene['condition'] != snapshot['weather']['icon']:
        raise ValueError('Scene must match the current local date, phase, and weather icon')
    observed = timestamp(snapshot['weather']['observed_at'])
    fetched = timestamp(snapshot['agenda']['fetched_at'])
    if max(observed, fetched) > now + timedelta(minutes=5):
        raise ValueError('Source timestamps cannot be in the future')
    image = Image.open(payload['art_path']).convert('L')
    if image.size != (800, 480):
        raise ValueError('Scene must be 800×480')
    draw = ImageDraw.Draw(image)
    # Exact data remains legible even if generated art strays into a reserved surface.
    draw.rectangle((44, 150, 216, 460), fill=255)
    draw.rectangle((281, 18, 766, 439), fill=255)
    def text(value, x, y, size, width, bold=False):
        lines, _ = wrap(value, size, width, bold, 1)
        if lines:
            draw.text((x, y), lines[0], font=font(size, bold), fill=0, anchor='lt')
    def number(value):
        if value is None:
            return '—'
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('Weather values must be finite numbers or null')
        return f'{value:g}'
    w = snapshot['weather']
    text(profile['location'].upper(), 46, 151, 14, 170, True)
    text(now.strftime('%a, %b ').upper() + str(now.day), 46, 173, 12, 170)
    text(number(w.get('temperature')) + '°', 44, 194, 61, 150, True)
    text('F', 198, 238, 14, 18)
    text(w['condition'], 46, 270, 21, 170, True)
    text('H ' + number(w.get('high')) + '°   L ' + number(w.get('low')) + '°', 46, 303, 19, 170)
    text('Wind ' + w.get('wind_direction', '') + ' ' + number(w.get('wind_speed')) + ' mph', 46, 336, 16, 170)
    chance = number(w.get('precipitation_chance')) + ('%' if w.get('precipitation_chance') is not None else '')
    text('Precip ' + w['precipitation_period'].lower() + ' ' + chance, 46, 366, 14, 170)
    text('UV now  ' + number(w.get('uv_current')), 46, 396, 18, 170, True)
    stale = (now - observed).total_seconds() > 5400 or w['forecast_date'] != now.date().isoformat()
    text(('STALE · ' if stale else '') + 'Weather ' + compact_time(observed.astimezone(now.tzinfo)), 46, 442, 10, 170, stale)
    rows = events_for(snapshot, profile, now)
    y, previous, shown, truncated = 18, None, 0, 0
    for day, _, __, label, e in rows:
        titles, cut = wrap(e['title'], 20, 362, True)
        details, _ = wrap(e.get('details') or '', 14, 362)
        times, time_cut = wrap(label, 16, 114, True, 3)
        if time_cut:
            raise ValueError('Event time range does not fit')
        height = max(len(titles)*23 + len(details)*17, len(times)*18 + 3) + (11 if details else 9)
        heading = 28 if previous != day else 0
        if y + heading + height > 431:
            break
        if heading:
            name = 'TODAY' if day == now.date() else 'TOMORROW' if day == now.date() + timedelta(days=1) else day.strftime('%A').upper()
            text(name + ' · ' + day.strftime('%b').upper() + ' ' + str(day.day), 282, y, 16, 484, True)
            draw.line((282, y+23, 766, y+23), fill=0)
            y += 28
        for n, line in enumerate(times): text(line, 282, y+3+n*18, 16, 114, True)
        for n, line in enumerate(titles): text(line, 404, y+n*23, 20, 362, True)
        for n, line in enumerate(details): text(line, 404, y+len(titles)*23+2+n*17, 14, 362)
        y += height
        shown += 1
        truncated += int(cut)
        previous = day
    if not rows:
        text('No upcoming events', 282, 45, 20, 484, True)
    failed = snapshot['agenda'].get('failed_calendars', [])
    stale_agenda = (now - fetched).total_seconds() > 7200
    footer = ('STALE · ' if stale_agenda else '') + 'Updated ' + compact_time(fetched.astimezone(now.tzinfo))
    if failed: footer += ' · ' + str(len(failed)) + ' calendars unavailable'
    if shown < len(rows): footer += ' · +' + str(len(rows)-shown) + ' more'
    text(footer, 282, 432, 10, 484, stale_agenda or bool(failed))
    return encode_png(image), {'shown': shown, 'omitted': len(rows)-shown, 'truncated_titles': truncated}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Render JSON, or source image with --normalize')
    parser.add_argument('output', type=Path)
    parser.add_argument('--normalize', action='store_true', help='Resize/crop to 800×480 and encode 2-bit grayscale, without drawing data')
    args = parser.parse_args()
    if args.normalize:
        from PIL import ImageOps
        result = encode_png(ImageOps.fit(Image.open(args.input), (800, 480), method=Image.Resampling.LANCZOS))
        receipt = {'normalized': True}
    else:
        result, receipt = render(json.loads(args.input.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.tmp')
    temporary.write_bytes(result)
    temporary.replace(args.output)
    print(json.dumps({**receipt, 'path': str(args.output), 'bytes': len(result), 'format': '800×480 PNG, 2-bit grayscale'}))

if __name__ == '__main__':
    main()
