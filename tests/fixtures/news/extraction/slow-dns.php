<?php
$socket=stream_socket_server('udp://127.0.0.1:53',$errno,$error,STREAM_SERVER_BIND);
if ($socket===false) { exit(1); }
file_put_contents('/work/dns-listening','ready');
while (true) { stream_socket_recvfrom($socket,4096); }
