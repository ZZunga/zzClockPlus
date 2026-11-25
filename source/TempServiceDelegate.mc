import Toybox.Background;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;

(:background)
class TempServiceDelegate extends System.ServiceDelegate {
    function initialize() { ServiceDelegate.initialize(); }

    function onTemporalEvent() as Void {
        var info = Sensor.getInfo();
        var t = (info has :temperature) ? info.temperature : null;
        Background.exit(t);
    }
}
