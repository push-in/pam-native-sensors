<?php

declare(strict_types=1);

use Pam\Native\Internal\Runtime;
use Pam\Native\Internal\Wire;
use Pam\Native\ModuleResultStatus;
use Pam\Native\Sensors\SensorType;
use Pam\Native\Sensors\Sensors;

require __DIR__.'/harness.php';

Sensors::read(SensorType::Gyroscope, static function (): void {
}, 50_000);
$sensorPayload = Wire::decodeMap(TestDiagnostics::$moduleCall['payload']);
$assert(
    TestDiagnostics::$moduleCall['module'] === 'sensors' && TestDiagnostics::$moduleCall['method'] === 'read'
        && $sensorPayload['type'] === SensorType::Gyroscope->value
        && $sensorPayload['timeoutMs'] === 10_000,
    'Sensor reads must use integer types and bounded native timeouts.',
);

$assert(
    array_map(static fn (SensorType $type): int => $type->value, SensorType::cases()) === [1, 2, 3, 4],
    'Sensor types must be sequential integers starting at 1.',
);
$reading = null;
Sensors::watch(SensorType::Accelerometer, static function ($value) use (&$reading): void {
    $reading = $value;
}, 5);
$watchCall = TestDiagnostics::$moduleCall;
$assert(
    $watchCall['module'] === 'sensors' && $watchCall['method'] === 'watch'
        && Wire::decodeMap($watchCall['payload']) == ['type' => 1, 'intervalMs' => 16],
    'Sensor watches must clamp the interval and call the sensors plugin module.',
);

echo "pam-native-sensors: {$tests} assertions passed\n";
