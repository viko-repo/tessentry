import tempfile, unittest, json, time
from pathlib import Path
from unittest.mock import patch
from tessentry import core

class TessentryTests(unittest.TestCase):
    def test_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'event.json'
            f.write_text(json.dumps({'camera':'6','timestamp':'2026-11-05T12:00:00','est_lat':31.5,'est_lon':34.5}))
            msg=core.event_text(Path(d),f)
            self.assertIn('Right fender',msg)
            self.assertIn('maps.google.com/?q=31.5,34.5',msg)
    def test_url(self):
        c=dict(core.DEFAULTS,openwa_url='http://100.75.224.110:2785')
        self.assertEqual(core.validate_openwa_url(c),c['openwa_url'])
        c['openwa_url']='http://127.0.0.1:2785'
        with self.assertRaises(ValueError):core.validate_openwa_url(c)
    def test_migration(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(core,'BASE',Path(d)):
                db=core.db(); cols={r[1] for r in db.execute('PRAGMA table_info(events)')}; db.close()
                self.assertTrue({'text_sent','video_sent'}<=cols)
    def test_discover(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)/'SentryClips'/'event-folder';folder.mkdir(parents=True)
            (folder/'event.mp4').write_bytes(b'video')
            cfg=dict(core.DEFAULTS,folders=[str(folder.parent)],settle_seconds=0)
            self.assertEqual(len(list(core.discover(cfg))),1)

if __name__=='__main__': unittest.main()
