# Scale down and then up the service that matched.
exec docker service scale %name%=0
exec docker service scale %name%=1
