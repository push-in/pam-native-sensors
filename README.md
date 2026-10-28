# PAM Native Sensors

Motion sensors for PAM Native apps: one-shot reads and throttled watches of the accelerometer, gyroscope, magnetometer and device motion.

Moved out of the PAM Native core in 1.46: the core keeps only the base every
app needs, and this feature ships as a plugin. The native module name and its
wire payloads did not change.

## Install

```bash
composer require pushinbr/pam-native-sensors
```

Requires `pushinbr/pam-native` 1.46 or newer (plugin hooks `WatchChannel` and
`ActivityResultHost`). The plugin is discovered from Composer; no manual
registration is needed.

## Use

```php
use Pam\Native\Sensors\SensorReading;
use Pam\Native\Sensors\Sensors;
use Pam\Native\Sensors\SensorType;

Sensors::read(SensorType::Accelerometer, static function (?SensorReading $reading): void {});
$watch = Sensors::watch(SensorType::Gyroscope, static function (SensorReading $reading): void {}, intervalMs: 50);
Sensors::unwatch($watch);
```

## Native

- Module: `sensors` (Android and iOS).
- Permissions: none.
- Android dependencies: none

## Migrating from the core

The 1.46 core keeps the old class names (`Pam\Native\System\...` and the
top-level value types) as deprecated aliases of this plugin's classes; they
are removed in 1.47. Replace the imports with the `Pam\Native\...` names
above.

## Tests

```bash
php tests/run.php            # after composer install
PAM_NATIVE_SRC=../pam-native/packages/native/src php tests/run.php
```
