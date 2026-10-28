<?php

declare(strict_types=1);

namespace Pam\Native\Sensors;

final readonly class SensorReading
{
    public function __construct(
        public SensorType $type,
        public float $x,
        public float $y,
        public float $z,
        public int $timestamp,
    ) {
    }
}
