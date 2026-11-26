import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

typedef Font as WatchUi.FontResource or Graphics.FontDefinition;

// zzClockPlus (zz시계 후속)
//  - 상태 줄: 온도, GPS 수신 단계, 배터리 % + 배터리 아이콘 (아이콘은 zzTimerFont 글리프)
//  - 시계: 10필드 칸은 시:분 (오전/오후는 시계 위, 540/840은 상태 줄 왼쪽), 넓은 칸은 시:분:초 (A/M 세로 표시)
//  - GPS 경고: 기록 시작/재개 후 30초 동안 GPS 미수신이면 배경이 빨갛게 깜빡임
//  - 마일리지: 활동 리셋 시 거리를 6개 소모품 항목에 누적, 교체 주기를 넘은 항목이 있으면 출발 후 30초 동안 파란 배경
//  - 온도: 백그라운드 서비스가 5분마다 기기 온도 센서 값을 저장 (Storage "sensorTemp")
class zzClockPlusView extends WatchUi.DataField {

    private const ALERT_SEC = 30;

    // ---- 설정 ----
    private var _is24 as Boolean = true;
    private var _tempF as Boolean = false;
    // 배경색 : 0 기기 화면색에 맞춤 (1050/1060 은 #17181D / #DCDCDC)
    //          1 기기가 알려준 검정·흰색 그대로 (기본, 지금까지의 동작)
    //          2 투명 - 칠하지 않아 기기 배경이 그대로 비친다
    enum { BG_AUTO, BG_PLAIN, BG_CLEAR }
    private var _bgMode as Number = BG_AUTO;
    private var _units as Boolean = true;
    private var _alertGps as Boolean = true;
    private var _alertMileage as Boolean = true;
    private var _distMetric as Boolean = true;

    // ---- 상태 ----
    private var _gps as Number = 0;              // 0~4 (Activity.Info.currentLocationAccuracy)
    private var _lastDist as Float = 0.0f;       // 마지막으로 본 활동 거리 (m)
    private var _alertLeft as Number = 0;        // 출발 후 경고 남은 초
    private var _gpsAlert as Boolean = false;
    private var _mileOver as Boolean = false;
    private var _firstStart as Boolean = true;
    private var _tick as Number = 0;

    // ---- 문자열 캐시 ----
    private var _tempV as Number = -9999, _tempS as String = "--";
    private var _battV as Number = -1, _battS as String = "--";
    private var _clockKey as Number = -1, _clockS as String = "--:--", _ampm as String = "";

    // ---- 레이아웃 ----
    private var _wide as Boolean = false;
    // 1050 / 1060 (화면폭 480 이상). onUpdate 에서 매번 묻지 않는다
    private var _big as Boolean = false;
    private var _low as Boolean = false;          // 높이가 낮은 넓은 칸: 한 줄 배치
    private var _amInRow as Boolean = false;      // 오전/오후를 상태 줄에 넣음 (540/840 10필드 칸)
    private var _L as Number = 0, _T as Number = 0, _R as Number = 0, _B as Number = 0;
    private var _fClock as Font = Graphics.FONT_XTINY, _fAm as Font = Graphics.FONT_XTINY;
    private var _fStat as Font = Graphics.FONT_XTINY, _fIcon as Font = Graphics.FONT_XTINY;
    private var _gap as Number = 2, _iconW as Number = 0, _battW as Number = 0;
    // 단위 숨김 모드(10필드 칸): 보통 값 기준의 큰 상태 폰트, 폭을 넘으면 기본 폰트로 자동 축소
    private var _fStatX as Font = Graphics.FONT_XTINY, _fIconX as Font = Graphics.FONT_XTINY;
    private var _yStatX as Number = 0, _gapX as Number = 2, _iconWX as Number = 0, _battWX as Number = 0;
    private var _useX as Boolean = false, _bigOk as Boolean = true, _fitChecked as Boolean = false;
    private var _yStat as Number = 0, _yIcon as Number = 0, _yClock as Number = 0, _yAm as Number = 0, _yAm2 as Number = 0;
    private var _xClockL as Number = 0, _xClockR as Number = 0;
    private var _amColW as Number = 0;

    function initialize() {
        DataField.initialize();
        readSettings();
    }

    function readSettings() as Void {
        var ds = System.getDeviceSettings();
        var h = numProp("hr24");
        _is24 = (h == 1) ? false : ((h == 2) ? true : ds.is24Hour);
        var u = numProp("unitMetric");
        _tempF = (u == 2) ? true : ((u == 1) ? false : (ds.temperatureUnits == System.UNIT_STATUTE));
        _distMetric = (ds.distanceUnits == System.UNIT_METRIC);
        _units    = boolProp("showUnits", true);
        _alertGps = boolProp("alertRecording", true);
        _alertMileage = boolProp("alertMileage", true);
        var bm = numProp("bgMode");
        _bgMode = (bm >= 0 && bm <= 2) ? bm : BG_AUTO;
        _tempV = -9999; _battV = -1; _clockKey = -1;
    }

    private function numProp(k as String) as Number {
        var v = Application.Properties.getValue(k);
        return (v instanceof Number) ? v : 0;
    }

    private function boolProp(k as String, def as Boolean) as Boolean {
        var v = Application.Properties.getValue(k);
        return (v instanceof Boolean) ? v : def;
    }

    // =========================================================
    // 레이아웃
    // =========================================================
    function onLayout(dc as Graphics.Dc) as Void {
        var w = dc.getWidth(), h = dc.getHeight();
        var sw = System.getDeviceSettings().screenWidth;
        _wide = w > sw * 0.75f;
        _big = (sw >= 480);
        _L = (w * 0.05f + 0.5f).toNumber();
        _T = (h * 0.05f + 0.5f).toNumber();
        _R = w - _L;
        _B = h - _T;
        var cm = (w * 0.03f + 0.5f).toNumber();          // 시계만 좌우 여백 3%
        _xClockL = cm; _xClockR = w - cm;
        var vg = (h * 0.05f + 0.5f).toNumber(); if (vg < 2) { vg = 2; }
        _clockKey = -1; _tempV = -9999; _battV = -1;     // 폭 계산 다시

        if (!_wide) {
            _fClock = loadFont(Rez.Fonts.Clock);
            _fAm    = loadFont(Rez.Fonts.AmPm);
            _fStat  = loadFont(_units ? Rez.Fonts.Status : Rez.Fonts.StatusY);   // 단위 숨김: 긴 값(-12, 100) 기준 크기
            _fIcon  = loadFont(_units ? Rez.Fonts.Icon : Rez.Fonts.IconY);
            var hIcon = Graphics.getFontHeight(_fIcon);
            _useX = !_units;
            if (_useX) {
                _fStatX = loadFont(Rez.Fonts.StatusX);
                _fIconX = loadFont(Rez.Fonts.IconX);
                _yStatX = _T + Graphics.getFontHeight(_fIconX) - Graphics.getFontAscent(_fStatX);
                _gapX = Graphics.getFontAscent(_fStatX) / 4; if (_gapX < 2) { _gapX = 2; }
                _iconWX = dc.getTextWidthInPixels("4", _fIconX);
                _battWX = dc.getTextWidthInPixels("F", _fIconX);
            } else {
                _fStatX = Graphics.FONT_XTINY; _fIconX = Graphics.FONT_XTINY;
            }
            var aClock = Graphics.getFontAscent(_fClock);
            _yClock = _B - aClock;
            _yIcon = _T;
            _yStat = _T + hIcon - Graphics.getFontAscent(_fStat);
            // 오전/오후를 시계 위에 둘 공간이 있는지
            var hAm = Graphics.getFontAscent(_fAm);
            _amInRow = (_T + hIcon + vg + hAm + vg > _yClock);
            _yAm = _amInRow ? (_T + hIcon - hAm) : (_yClock - vg - hAm);
            _low = false;
        } else {
            _fStat = loadFont(Rez.Fonts.WStatus);
            _fIcon = loadFont(Rez.Fonts.WIcon);
            _fAm   = loadFont(Rez.Fonts.WAmPm);
            var hIcon = Graphics.getFontHeight(_fIcon);
            var fc = loadFont(Rez.Fonts.WClock);
            _low = (_T + hIcon + vg + Graphics.getFontAscent(fc) > _B);
            if (_low) {
                // 낮은 넓은 칸 (550/850의 420x60 등): 왼쪽 시계(초 없음), 오른쪽 상태
                _fClock = loadFont(Rez.Fonts.ClockLow);
                _fStat  = loadFont(_units ? Rez.Fonts.Status : Rez.Fonts.StatusN);
                _fIcon  = loadFont(_units ? Rez.Fonts.Icon : Rez.Fonts.IconN);
                _fAm    = loadFont(Rez.Fonts.AmPm);
                hIcon = Graphics.getFontHeight(_fIcon);
                _yClock = _B - Graphics.getFontAscent(_fClock);
                _yIcon = (_T + _B - hIcon) / 2;
            } else {
                _fClock = fc;
                _yClock = _B - Graphics.getFontAscent(_fClock);
                _yIcon = _T;
            }
            _yStat = _yIcon + hIcon - Graphics.getFontAscent(_fStat);
            var aAm = Graphics.getFontAscent(_fAm);
            _yAm2 = _B - aAm;                                   // A/M 세로: 아래 글자(M)는 시계 바닥선
            _yAm  = _yAm2 - (Graphics.getFontAscent(_fClock) - aAm);   // 위 글자(A)는 시계 윗선
            _amColW = dc.getTextWidthInPixels("M", _fAm);
            _amInRow = false;
            _useX = false;
        }
        _gap = (Graphics.getFontAscent(_fStat) / 4); if (_gap < 2) { _gap = 2; }
        _iconW = dc.getTextWidthInPixels("4", _fIcon);
        _battW = dc.getTextWidthInPixels("F", _fIcon);
    }

    private function loadFont(id as Lang.ResourceId) as Font {
        return WatchUi.loadResource(id) as WatchUi.FontResource;
    }

    // =========================================================
    // 계산 (1초마다)
    // =========================================================
    function onTimerStart() as Void {
        _alertLeft = ALERT_SEC;
        if (_firstStart) {                       // 마일리지 경고는 활동의 첫 출발 때만
            _mileOver = _alertMileage && Mileage.isOver();
            _firstStart = false;
        } else {
            _mileOver = false;
        }
    }

    function onTimerReset() as Void {
        if (_lastDist > 0.0f) { Mileage.add(_lastDist, _distMetric); }
        _lastDist = 0.0f; _firstStart = true; _alertLeft = 0; _mileOver = false; _gpsAlert = false;
    }

    function compute(info as Activity.Info) as Void {
        _tick += 1;
        var acc = info.currentLocationAccuracy;
        _gps = (acc == null) ? 0 : acc;
        var d = info.elapsedDistance;
        if (d != null && d > 0) { _lastDist = d; }

        if (_alertLeft > 0) {
            _alertLeft -= 1;
            _gpsAlert = _alertGps && (info.timerState == Activity.TIMER_STATE_ON) && (_gps < 2);
            if (_gps >= 2) { _gpsAlert = false; }
        } else {
            _gpsAlert = false; _mileOver = false;
        }
    }

    // =========================================================
    // 그리기
    // =========================================================
    function onUpdate(dc as Graphics.Dc) as Void {
        var sys = getBackgroundColor();
        var sysClear = (sys == Graphics.COLOR_TRANSPARENT);   // 기기가 "투명"이라고 알려준 경우
        var night = (sys == Graphics.COLOR_BLACK || sysClear);
        var soft = (_bgMode == BG_AUTO) && _big;   // _big = 1050 / 1060
        var fg = night ? Graphics.COLOR_WHITE
                       : (soft ? 0x313152 : Graphics.COLOR_BLACK);
        var bg = night ? (soft ? 0x17181D : Graphics.COLOR_BLACK)
                       : (soft ? 0xDCDCDC : Graphics.COLOR_WHITE);
        // 투명 : 칠하지 않아 기기 배경이 그대로 비친다 (경보 때는 아래에서 덮어쓴다)
        if (_bgMode == BG_CLEAR || (_bgMode == BG_AUTO && sysClear)) {
            bg = Graphics.COLOR_TRANSPARENT;
        }
        var alertBg = false;
        if (_gpsAlert) {                              // 1초 간격 깜빡임
            if (_tick % 2 == 0) { bg = Graphics.COLOR_RED; alertBg = true; }
        } else if (_mileOver) {
            bg = Graphics.COLOR_BLUE; alertBg = true;
        }
        if (alertBg) { fg = Graphics.COLOR_WHITE; }
        dc.setColor(fg, bg);
        dc.clear();
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }

        updateStrings();
        drawStatus(dc, fg, night, alertBg);
        drawClock(dc, fg);
    }

    private function updateStrings() as Void {
        // 온도 (백그라운드 서비스가 저장한 값, 섭씨)
        var t = Application.Storage.getValue("sensorTemp");
        var tv = -9999;
        if (t instanceof Number || t instanceof Float) {
            var c = t.toFloat();
            var tc = _tempF ? (c * 1.8f + 32.0f) : c;
            tv = (tc + (tc < 0.0f ? -0.5f : 0.5f)).toNumber();     // 영하도 올바르게 반올림
        }
        if (tv != _tempV) {
            _tempV = tv;
            _tempS = (tv == -9999) ? "--" : (tv.toString() + (_units ? (_tempF ? "F" : "C") : ""));
            _bigOk = true; _fitChecked = false;
        }
        // 배터리
        var bv = (System.getSystemStats().battery + 0.5f).toNumber();
        if (bv != _battV) { _battV = bv; _battS = bv.toString() + (_units ? "%" : ""); _fitChecked = false; }
        // 시계
        var ct = System.getClockTime();
        var key = _wide && !_low ? (ct.hour * 3600 + ct.min * 60 + ct.sec) : (ct.hour * 60 + ct.min);
        if (key != _clockKey) {
            _clockKey = key;
            var hr = ct.hour;
            if (!_is24) {
                _ampm = _units ? ((hr < 12) ? "AM" : "PM") : "";    // 단위 숨김 모드에서는 오전/오후도 숨김
                hr = hr % 12; if (hr == 0) { hr = 12; }
            } else {
                _ampm = "";
            }
            _clockS = hr.toString() + ":" + ct.min.format("%02d");
            if (_wide && !_low) { _clockS += ":" + ct.sec.format("%02d"); }
        }
    }

    // [오전/오후] 온도 [GPS] 배터리% [배터리]
    private function drawStatus(dc as Graphics.Dc, fg as Number, night as Boolean, alertBg as Boolean) as Void {
        var stats = System.getSystemStats();
        var fS = _fStat, fI = _fIcon, yS = _yStat, gap = _gap, iw = _iconW, bw = _battW;
        if (_useX) {
            if (!_fitChecked) {                      // 값이 바뀐 경우에만 폭 확인
                var tot = dc.getTextWidthInPixels(_tempS, _fStatX) + _gapX + _iconWX + _gapX
                        + dc.getTextWidthInPixels(_battS, _fStatX) + _gapX / 2 + _battWX;
                _bigOk = (tot <= _R - _L);
                _fitChecked = true;
            }
            if (_bigOk) { fS = _fStatX; fI = _fIconX; yS = _yStatX; gap = _gapX; iw = _iconWX; bw = _battWX; }
        }
        var wT = dc.getTextWidthInPixels(_tempS, fS);
        var wB = dc.getTextWidthInPixels(_battS, fS);
        var amW = (_amInRow && _ampm.length() > 0) ? dc.getTextWidthInPixels(_ampm, _fAm) + gap : 0;
        var total = amW + wT + gap + iw + gap + wB + gap / 2 + bw;
        var x;
        if (_low) { x = _R - total; }                      // 낮은 넓은 칸: 오른쪽 정렬
        else      { x = (_L + _R - total) / 2; if (x < _L) { x = _L; } }

        if (amW > 0) {
            dc.setColor(alertBg ? fg : Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, yS + Graphics.getFontAscent(fS) - Graphics.getFontAscent(_fAm), _fAm, _ampm, Graphics.TEXT_JUSTIFY_LEFT);
            x += amW;
        }
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, yS, fS, _tempS, Graphics.TEXT_JUSTIFY_LEFT);
        x += wT + gap;

        // GPS: 0단계(신호 없음) = 회색 사선 아이콘, 1~4단계 = 회색 막대 위에 단계만큼 주황으로 칠함
        if (_gps <= 0) {
            dc.setColor(alertBg ? fg : (night ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY), Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, _yIcon, fI, "0", Graphics.TEXT_JUSTIFY_LEFT);
        } else {
            dc.setColor(night ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_gps < 4) { dc.drawText(x, _yIcon, fI, "4", Graphics.TEXT_JUSTIFY_LEFT); }
            dc.setColor(alertBg ? fg : 0xFF5500, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, _yIcon, fI, (_gps > 4 ? 4 : _gps).toString(), Graphics.TEXT_JUSTIFY_LEFT);
        }
        x += iw + gap;

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, yS, fS, _battS, Graphics.TEXT_JUSTIFY_LEFT);
        x += wB + gap / 2;

        // 배터리 아이콘: 충전 중 A, 잔량 B(0)~F(100). 15% 미만 빨강, 30% 미만 노랑, 그 외 초록
        var ch = (stats has :charging && stats.charging) ? "A" : ["B", "C", "D", "E", "F"][(_battV + 12) / 25 > 4 ? 4 : (_battV + 12) / 25] as String;
        var col = (_battV < 15) ? Graphics.COLOR_RED : ((_battV < 30) ? 0xFFAA00 : 0x00AA00);
        dc.setColor(alertBg ? fg : col, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, _yIcon, fI, ch, Graphics.TEXT_JUSTIFY_LEFT);
    }

    private function drawClock(dc as Graphics.Dc, fg as Number) as Void {
        var wC = dc.getTextWidthInPixels(_clockS, _fClock);
        var hasAm = (_ampm.length() > 0);
        if (!_wide) {
            var x = (_xClockL + _xClockR - wC) / 2;
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, _yClock, _fClock, _clockS, Graphics.TEXT_JUSTIFY_LEFT);
            if (hasAm && !_amInRow) {                       // 시계 위, 시계 왼쪽 끝에 맞춤
                dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x, _yAm, _fAm, _ampm, Graphics.TEXT_JUSTIFY_LEFT);
            }
            return;
        }
        // 넓은 칸: [A/M 세로][시계]
        var colW = hasAm ? (_amColW + _gap) : 0;
        var x = _low ? _xClockL : (_xClockL + _xClockR - wC - colW) / 2;
        if (hasAm) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x + _amColW / 2, _yAm,  _fAm, _ampm.substring(0, 1), Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(x + _amColW / 2, _yAm2, _fAm, "M", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + colW, _yClock, _fClock, _clockS, Graphics.TEXT_JUSTIFY_LEFT);
    }
}

// 소모품 마일리지 (설정의 label/limit/value 1~6, 단위는 기기 거리 단위)
module Mileage {
    function isOver() as Boolean {
        for (var i = 1; i <= 6; i++) {
            var v = Application.Properties.getValue("value" + i);
            var l = Application.Properties.getValue("limit" + i);
            if (v instanceof Number && l instanceof Number && l > 0 && v >= l) { return true; }
        }
        return false;
    }

    function add(meters as Float, metric as Boolean) as Void {
        var d = (metric ? meters / 1000.0f : meters / 1609.344f) + 0.5f;
        var n = d.toNumber();
        if (n <= 0) { return; }
        for (var i = 1; i <= 6; i++) {
            var v = Application.Properties.getValue("value" + i);
            if (v instanceof Number) { Application.Properties.setValue("value" + i, v + n); }
        }
    }
}
