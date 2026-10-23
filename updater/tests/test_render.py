import importlib.util
import unittest
from pathlib import Path
from datetime import datetime, timezone
from PIL import Image

spec = importlib.util.spec_from_file_location('render', Path(__file__).resolve().parents[1] / 'render.py')
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)

class RenderTests(unittest.TestCase):
    def test_png_is_two_bit_grayscale(self):
        png = r.encode_png(Image.new('L', (800,480), 85))
        self.assertEqual(png[24:26], bytes([2,0]))
        self.assertLess(len(png), 90000)
        import io
        decoded = Image.open(io.BytesIO(png)); self.assertEqual(decoded.size, (800,480)); self.assertEqual(decoded.getpixel((0,0)),85)
    def test_invalid_size(self):
        with self.assertRaises(ValueError): r.encode_png(Image.new('L',(100,100)))
    def test_timezone_is_required(self):
        with self.assertRaises(ValueError): r.timestamp('2026-10-14T12:00:00')
    def test_original_time_for_ongoing_event(self):
        now = r.timestamp('2026-10-14T19:30:00-05:00')
        snapshot={'agenda':{'events':[{'id':'a','calendar':'example','title':'Example event','start':'2026-10-14T19:00:00-05:00','end':'2026-10-14T20:00:00-05:00','all_day':False}]}}
        rows = r.events_for(snapshot, {'lookahead_days':7}, now)
        self.assertEqual(rows[0][3], '7p-8p')
    def test_all_day_exclusive_end(self):
        # The updater normalizes midnight source ranges to date-only boundaries.
        cases = [
            ('2026-06-12', '2026-06-13', '-05:00', ['2026-06-12']),
            ('2026-10-29', '2026-11-03', '-05:00',
             ['2026-10-29', '2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02']),
            ('2026-03-07', '2026-03-10', '-06:00',
             ['2026-03-07', '2026-03-08', '2026-03-09']),
        ]
        from zoneinfo import ZoneInfo
        for start, end, offset, expected_days in cases:
            with self.subTest(start=start, end=end):
                now = r.timestamp(start + 'T12:00:00' + offset).astimezone(ZoneInfo('America/Chicago'))
                snapshot = {'agenda': {'events': [{'id': 'a', 'calendar': 'example',
                    'title': 'Example', 'start': start, 'end': end, 'all_day': True}]}}
                rows = r.events_for(snapshot, {'lookahead_days': 7}, now)
                self.assertEqual([row[0].isoformat() for row in rows], expected_days)
                self.assertTrue(all(row[3] == 'ALL DAY' for row in rows))
                self.assertTrue(all(row[4]['end'] == end for row in rows))
    def test_day_phase(self):
        for hour, expected in [(4,'night'),(5,'morning'),(12,'afternoon'),(17,'evening'),(21,'night')]: self.assertEqual(r.phase(datetime(2026,1,1,hour,tzinfo=timezone.utc)),expected)
    def test_long_words_are_bounded(self):
        lines,truncated=r.wrap('abcdefghij'*30,20,114,True)
        self.assertTrue(truncated)
        self.assertTrue(all(r.font(20,True).getlength(line)<=114 for line in lines))

if __name__ == '__main__': unittest.main()
