"""Validate observations of real configured controls, never synthesize frames."""

import math

MATH_PROBES = ('composer-inline-math-light', 'composer-inline-math-dark')
PILL_PROBES = ('pill-cache-initial', 'pill-cache-enabled', 'pill-dark-header',
               'pill-provider-loading', 'pill-provider-ready', 'pill-reloaded')


def validate_control(value, identifier, leading, trailing):
    if (value.get('id') != identifier or value.get('inWindow') is not True or not value.get('title')
            or value.get('label') != value.get('title')):
        raise ValueError('Missing actual configured UIButton evidence: ' + identifier)
    for key in ('buttonFrame', 'labelFrame'):
        frame = value.get(key, [])
        if len(frame) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in frame) or min(frame[2:]) <= 0:
            raise ValueError('Missing actual configured control geometry')
    x, y, width, height = value['buttonFrame']
    lx, ly, lw, lh = value['labelFrame']
    if height < 44 or lx < x - 0.5 or ly < y - 0.5 or lx + lw > x + width + 0.5 or ly + lh > y + height + 0.5:
        raise ValueError('Configured native button title is clipped')
    insets = value.get('insets', [])
    if len(insets) != 4 or insets[1] != leading or insets[3] != trailing or not value.get('font') or value.get('pointSize', 0) <= 0:
        raise ValueError('Configured native button lost its insets/font')


def validate_control_probes(probes, scenario):
    by_name = {probe['name']: probe for probe in probes}
    if scenario == 'composer-render':
        for index, name in enumerate(MATH_PROBES):
            probe = by_name.get(name, {})
            value = probe.get('semantic', {}).get('configurationControl', {})
            validate_control(value, 'exteraless.inlineMath.insert', 14, 14)
            if value['title'] != '= 3  ·  Insert' or probe.get('dark') is not bool(index):
                raise ValueError('Inline calculation control was not recorded in both palettes')
    elif scenario == 'pill-render':
        for name in PILL_PROBES:
            value = by_name.get(name, {}).get('semantic', {}).get('configurationControl', {})
            validate_control(value, 'exteraless.pill.current', 38, 16)
        if by_name['pill-cache-initial'].get('dark') is not False or by_name['pill-dark-header'].get('dark') is not True:
            raise ValueError('Pill configured control did not retain light/dark evidence')
