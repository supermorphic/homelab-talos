<?php
declare(strict_types=1);
require __DIR__ . '/runtime.php';
try {
    echo NewsExtraction\verifyRuntime('/work/current', dirname(__DIR__))->id(), "\n";
} catch (Throwable $e) { exit(1); }
