"""Spatial/quality checks for the host calibration fitter, independent fixtures."""
import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import tempfile

root = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('checkerboard', str(root / '.script/calibrate-checkerboard'))
spec = importlib.util.spec_from_loader(loader.name, loader)
fit = importlib.util.module_from_spec(spec)
loader.exec_module(fit)

def board(white=(90, 120, 100), split=False):
    data = bytearray()
    for y in range(54):
        for x in range(96):
            light = x >= 48 if split else (x // 8 + y // 6) % 2 == 0
            data.extend(white if light else (8, 10, 12))
    return bytes(data)

with tempfile.TemporaryDirectory() as name:
    d = Path(name)
    for k in range(4):
        data = bytearray(board())
        data[0] += k # Distinct sensor frames; outside the fitted central ROI.
        (d / f'frame-{k:02d}.rgb').write_bytes(data)
    with contextlib.redirect_stdout(io.StringIO()):
        result = fit.analyze(d)
    assert result['white_rgb'] == [90, 120, 100]
    assert result['black_rgb'] == [8, 10, 12]
    assert result['gains_q8'][0] > result['gains_q8'][2] > result['gains_q8'][1]
    corrected = fit.display(bytes((90, 120, 100)), result['gains_q8'], result['display_black_points'])
    assert max(corrected) - min(corrected) <= 1, corrected
    dark = fit.display(bytes((8, 10, 12)), result['gains_q8'], result['display_black_points'])
    assert max(dark) - min(dark) <= 1, dark
    for wrong in [board(split=True), board((255, 255, 255))]:
        try:
            fit.measure(wrong)
        except RuntimeError:
            pass
        else:
            raise AssertionError('Non-board/clipped image accepted')
    (d / 'frame-03.rgb').write_bytes(board((110, 140, 120)))
    try:
        fit.analyze(d)
    except RuntimeError as e:
        assert 'changed' in str(e)
    else:
        raise AssertionError('Exposure drift accepted')
print('PASS checkerboard fit: neutral white, square interiors, split-wall/clipping/exposure-drift rejection')
