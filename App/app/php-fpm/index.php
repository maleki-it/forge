<?php
/**
 * Demo endpoint: returns JSON showing how the client IP was detected.
 *
 * Request path:
 *   Client → NGINX (LoadBalancer) → PHP-FPM (FastCGI) → this file
 *
 * NGINX sets REMOTE_ADDR from X-Forwarded-For (see k8s/03-nginx-configmap.yaml).
 * PHP reads $_SERVER values that NGINX/FastCGI pass through.
 */
declare(strict_types=1);

header('Content-Type: application/json');

// REMOTE_ADDR: IP NGINX believes is the client (after real_ip processing).
$remoteAddr = $_SERVER['REMOTE_ADDR'] ?? 'unknown';

// X-Forwarded-For: original header chain from proxies/LB, if any.
// Example: "203.0.113.10, 10.0.0.1" (left-most is usually the original client).
$xff = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? '';

// Use the first IP in X-Forwarded-For when present; otherwise fall back to REMOTE_ADDR.
$forwardedIp = '';
if ($xff !== '') {
    $parts = explode(',', $xff);
    $forwardedIp = trim($parts[0]);
}

$clientIp = $forwardedIp !== '' ? $forwardedIp : $remoteAddr;

echo json_encode([
    'message' => 'Hello from PHP-FPM behind NGINX',
    'client_ip' => $clientIp,           // best guess of the real user IP
    'remote_addr' => $remoteAddr,       // what PHP received as REMOTE_ADDR from NGINX
    'x_forwarded_for' => $xff,          // raw header for debugging
    'host' => gethostname(),            // pod hostname (useful in multi-replica setups)
], JSON_PRETTY_PRINT) . PHP_EOL;
