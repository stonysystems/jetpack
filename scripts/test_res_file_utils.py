"""Tests for res_file_utils module."""

import os
import tempfile
import unittest
import unittest.mock as mock

from res_file_utils import read_res_tail, read_res_full, MAX_RES_FILE_SIZE, TAIL_BYTES


class TestReadResTail(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write(self, name, content):
        path = os.path.join(self.tmpdir, name)
        with open(path, 'w') as f:
            f.write(content)
        return path

    def test_reads_small_file_completely(self):
        path = self._write("small.res", "Mid throughput is 100.0\nDone\n")
        lines = read_res_tail(path)
        self.assertEqual(len(lines), 2)
        self.assertIn("Mid throughput is 100.0", lines[0])

    def test_reads_tail_of_large_file(self):
        # Create file larger than TAIL_BYTES
        padding = "x" * 200 + "\n"
        n_lines = (TAIL_BYTES // len(padding)) + 100
        content = padding * n_lines + "Mid throughput is 42.0\n"
        path = self._write("large.res", content)
        lines = read_res_tail(path)
        # Should find the summary line at end
        self.assertTrue(any("Mid throughput is 42.0" in l for l in lines))
        # Should NOT contain ALL the padding lines (tail only)
        self.assertLess(len(lines), n_lines)

    def test_missing_file_returns_empty(self):
        lines = read_res_tail("/nonexistent/path.res")
        self.assertEqual(lines, [])

    def test_oversized_file_returns_empty(self):
        path = self._write("tiny.res", "data\n")
        with mock.patch('res_file_utils.os.path.getsize',
                        return_value=MAX_RES_FILE_SIZE + 1):
            lines = read_res_tail(path)
        self.assertEqual(lines, [])

    def test_custom_tail_bytes(self):
        content = "line1\nline2\nline3\nMid throughput is 50.0\n"
        path = self._write("custom.res", content)
        # Read with small tail
        lines = read_res_tail(path, tail_bytes=30)
        self.assertTrue(any("Mid throughput" in l for l in lines))

    def test_binary_safe(self):
        path = os.path.join(self.tmpdir, "binary.res")
        with open(path, 'wb') as f:
            f.write(b'\x00\xff\xfe' + b'Mid throughput is 10.0\n')
        lines = read_res_tail(path)
        self.assertTrue(any("Mid throughput" in l for l in lines))

    def test_empty_file(self):
        path = self._write("empty.res", "")
        lines = read_res_tail(path)
        self.assertEqual(lines, [])


class TestReadResFull(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_reads_entire_file(self):
        path = os.path.join(self.tmpdir, "full.res")
        with open(path, 'w') as f:
            f.write("line1\nline2\nline3\n")
        lines = read_res_full(path)
        self.assertEqual(len(lines), 3)

    def test_missing_file_returns_empty(self):
        lines = read_res_full("/nonexistent/path.res")
        self.assertEqual(lines, [])

    def test_oversized_file_returns_empty(self):
        path = os.path.join(self.tmpdir, "full.res")
        with open(path, 'w') as f:
            f.write("data\n")
        with mock.patch('res_file_utils.os.path.getsize',
                        return_value=MAX_RES_FILE_SIZE + 1):
            lines = read_res_full(path)
        self.assertEqual(lines, [])


class TestConstants(unittest.TestCase):
    def test_max_size_is_2gb(self):
        self.assertEqual(MAX_RES_FILE_SIZE, 2_000_000_000)

    def test_tail_bytes_is_100kb(self):
        self.assertEqual(TAIL_BYTES, 100_000)


if __name__ == "__main__":
    unittest.main()
