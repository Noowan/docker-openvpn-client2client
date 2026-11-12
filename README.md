# OpenVPN в Docker

UDP-порт: `24443`. VPN-сеть: `10.77.0.0/24`.
Перед запуском укажите адрес VPS в `OVPN_REMOTE` в `compose.yaml`.

## Подготовка VPS

Команды выполняются из каталога проекта с Dockerfile и compose.yaml.
```bash
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-openvpn.conf
sudo sysctl -p /etc/sysctl.d/99-openvpn.conf

sudo ufw allow 24443/udp

mkdir -p openvpn-data/ccd
docker compose build
docker compose run --rm openvpn init
```

## Создание клиентов

Имя клиента должно совпадать с именем его CCD-файла.
```bash
docker compose run --rm openvpn client site-a
docker compose run --rm openvpn client site-b
```

Готовые профили для импорта на клиентах:
```text
openvpn-data/clients/site-a/site-a.ovpn
openvpn-data/clients/site-b/site-b.ovpn
```

Профили содержат закрытые ключи — передавать только владельцам.

## Соединение двух LAN
LAN-сети не должны пересекаться друг с другом, VPN и Docker-сетью.

```bash
cat << 'EOF' > openvpn-data/ccd/site-a
ifconfig-push 10.77.0.10 255.255.255.0
iroute 10.10.1.0 255.255.255.0
push "route 10.10.2.0 255.255.255.0"
EOF

cat << 'EOF' > openvpn-data/ccd/site-b
ifconfig-push 10.77.0.11 255.255.255.0
iroute 10.10.2.0 255.255.255.0
push "route 10.10.1.0 255.255.255.0"
EOF
```

## Запуск и обслуживание
```bash
docker compose up -d

# Журнал
docker compose logs -f openvpn

# Перезапуск, в том числе после изменения CCD
docker compose restart openvpn

# Остановка
docker compose down
```

## Отзыв клиентского сертификата
```bash
docker compose run --rm openvpn revoke site-a
docker compose restart openvpn
```

Перезапуск отключит текущие соединения. Отозванный сертификат больше не сможет подключиться. Удаление `.ovpn` или CCD-файла само по себе сертификат не отзывает.