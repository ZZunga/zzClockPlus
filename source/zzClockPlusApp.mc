import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

(:background)
class zzClockPlusApp extends Application.AppBase {
    private var _view as zzClockPlusView?;

    function initialize() { AppBase.initialize(); }

    (:typecheck(disableBackgroundCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        _view = new zzClockPlusView();
        if (System has :ServiceDelegate) {
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));   // 5분마다 온도 읽기
        }
        return [_view as zzClockPlusView];
    }

    function getServiceDelegate() as [System.ServiceDelegate] {
        return [new TempServiceDelegate()];
    }

    // 백그라운드 서비스가 보낸 온도(섭씨) 저장
    function onBackgroundData(data as Application.PersistableType) as Void {
        if (data instanceof Number || data instanceof Float) {
            Application.Storage.setValue("sensorTemp", data);
            WatchUi.requestUpdate();
        }
    }

    (:typecheck(disableBackgroundCheck))
    function onSettingsChanged() as Void {
        if (_view != null) { (_view as zzClockPlusView).readSettings(); }
        WatchUi.requestUpdate();
    }
}
