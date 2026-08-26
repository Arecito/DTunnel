#!/bin/bash

# 1. Validar permisos de Root de forma segura
if [[ "$EUID" -ne 0 ]]; then
  echo
  echo "¡Instale como usuario Root!"
  echo
  rm -f "$0"
  exit 1
fi

# 2. Validar versión de Ubuntu
ubuntuV=$(lsb_release -rs 2>/dev/null | cut -d. -f1)

if [[ -z "$ubuntuV" || "$ubuntuV" -lt 20 ]]; then
  clear
  echo "La versión de Ubuntu debe ser mínimo 20, la suya es: ${ubuntuV:-Desconocida}"
  echo
  rm -f "$0"
  exit 1
fi

# 3. Comprobar instalación previa y desinstalación/respaldo
if [[ -e /etc/DTunnel/src/index.ts ]]; then
  clear
  echo "El Panel ya está instalado, ¿desea eliminarlo? (s/n)"
  read -r remo
  if [[ "$remo" =~ ^[sS]$ ]]; then
    cd /etc/DTunnel || exit 1
    rm -rf painelbackup > /dev/null 2>&1
    mkdir -p painelbackup > /dev/null 2>&1
    cp prisma/database.db painelbackup/ 2>/dev/null
    cp .env painelbackup/ 2>/dev/null
    
    tar -czf painelbackup.tar.gz painelbackup 2>/dev/null
    mv painelbackup.tar.gz /root/ 2>/dev/null
    
    # Detener tanto el panel como Prisma Studio al desinstalar
    pm2 delete ecosystem.config.js > /dev/null 2>&1
    pm2 delete PrismaStudio > /dev/null 2>&1
    
    # Eliminar binarios de gestión (incluyendo pupdate)
    rm -f /bin/pon /bin/poff /bin/pmenu /bin/backmod /bin/pupdate 2>/dev/null
    rm -rf /etc/DTunnel
    rm -f "$0"
    echo "¡Eliminado con éxito! Respaldo guardado en /root/painelbackup.tar.gz"
    exit 0
  fi
  exit 0
fi

clear
echo "=========================================="
echo "      CONFIGURACIÓN DEL PANEL DTUNNEL     "
echo "=========================================="
echo
echo "Ingrese el IP o Dominio del servidor (ej. panel.midominio.com o 192.168.1.1):"
read -r domain
echo

ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
is_domain=false

if [[ $domain =~ $ip_regex ]]; then
  echo "Se detectó una dirección IP."
  echo "¿En qué puerto desea activar el panel?"
  read -r porta
  echo
else
  echo "Se detectó un Dominio. Se configurará el pase de tráfico por HAProxy en el puerto 8443."
  porta=8443
  is_domain=true
  echo
fi

echo "Instalando dependencias del sistema y herramientas de compilación..."
echo
sleep 2

# Forzar IPv4 en apt-get para evitar cuelgues de red IPv6
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Actualizar paquetes e instalar dependencias nativas
apt-get update -y
apt-get install wget curl zip unzip cron screen git tar build-essential make gcc g++ python3 -y

# Instalación de Node.js v20 (LTS)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install nodejs -y

# Herramientas globales de Node.js
npm install -g pm2 typescript ts-node

# Clonar Repositorio
cd /etc/ || exit 1
git clone https://github.com/Arecito/DTunnel.git
cd /etc/DTunnel || exit 1

# Otorgar permisos y mover comandos a /bin/ (incluyendo pupdate)
chmod +x pon poff pmenu backmod pupdate 2>/dev/null
cp pon poff pmenu backmod pupdate /bin/ 2>/dev/null
chmod +x /bin/pon /bin/poff /bin/pmenu /bin/backmod /bin/pupdate 2>/dev/null

cp .env.example .env 2>/dev/null || touch .env

# Si es un dominio, hacemos que DTunnel corra internamente en el puerto 8085
# para que HAProxy tome el 8443 y le pase el tráfico.
app_port=$porta
if [ "$is_domain" = true ]; then
  app_port=8085
fi

# Guardar variables de entorno
echo "DOMAIN=$domain" > .env
echo "PORT=$app_port" >> .env
echo "NODE_ENV=\"production\"" >> .env
echo "DATABASE_URL=\"file:./database.db\"" >> .env

echo "Generando llaves de seguridad..."
token1=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'));")
token2=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'));")
token3=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'));")
echo "CSRF_SECRET=\"$token1\"" >> .env
echo "JWT_SECRET_KEY=\"$token2\"" >> .env
echo "JWT_SECRET_REFRESH=\"$token3\"" >> .env

echo "Instalando módulos de Node.js..."
npm install

echo "Garantizando dependencias necesarias..."
npm install dotenv bcrypt --build-from-source

echo "Aplicando parches al código fuente y esquema..."
# 1. Habilitar la característica omitApi en Prisma Schema
if [[ -f prisma/schema.prisma ]]; then
  grep -q 'previewFeatures' prisma/schema.prisma || sed -i '/generator client {/a \  previewFeatures = ["omitApi"]' prisma/schema.prisma
fi

# 2. Corregir sintaxis de Zod en login.ts
if [[ -f src/routes/Authentication/login.ts ]]; then
  sed -i 's/z\.email()/z.string().email()/g' src/routes/Authentication/login.ts
fi

echo "Configurando base de datos (Prisma)..."
npx prisma generate
npx prisma db push

echo "Compilando proyecto TypeScript..."
npx tsc || true

# Configuración automática de HAProxy si se ingresó un Dominio
if [ "$is_domain" = true ] && [ -f /etc/haproxy/haproxy.cfg ]; then
  echo "Integrando reglas del Panel y Prisma Studio en HAProxy (Puerto 8443)..."
  
  # Buscar un certificado .pem existente que use HAProxy
  cert_file=$(grep -oE 'crt /[^ ]+' /etc/haproxy/haproxy.cfg | head -n 1 | awk '{print $2}')

  if [ -z "$cert_file" ]; then
    cert_file="/etc/haproxy/cert.pem"
  fi

  # Limpieza exhaustiva de cualquier bloque previo para evitar duplicaciones
  sed -i '/# --- CONFIGURACION PANEL DTUNNEL/,$d' /etc/haproxy/haproxy.cfg
  sed -i '/frontend panel_8443/,$d' /etc/haproxy/haproxy.cfg

  cat <<EOF >> /etc/haproxy/haproxy.cfg

# --- CONFIGURACION PANEL DTUNNEL Y PRISMA STUDIO ---
frontend panel_8443
    bind *:8443 ssl crt $cert_file
    mode http

    acl is_studio path_beg /studio
    use_backend studio_backend if is_studio

    default_backend panel_backend

backend panel_backend
    mode http
    server dtunnel_local 127.0.0.1:8085 check

backend studio_backend
    mode http
    reqrep ^([^\ ]*\ )/studio[/]?(.*) \1/\2
    server studio_local 127.0.0.1:5656 check
EOF

  # Validar que la sintaxis de HAProxy sea correcta antes de reiniciar el servicio
  if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
    systemctl restart haproxy 2>/dev/null || service haproxy restart 2>/dev/null
    echo "¡HAProxy actualizado y reiniciado con éxito!"
  else
    echo "⚠️ Advertencia: Error en la sintaxis de HAProxy. No se reinició el servicio para evitar caídas del servidor."
  fi
fi

echo "Configurando e iniciando Prisma Studio en segundo plano..."
pm2 delete PrismaStudio 2>/dev/null || true
pm2 start "npx prisma studio --port 5656 --hostname 0.0.0.0 --browser none" --name PrismaStudio

echo "Iniciando Panel con PM2..."
pm2 start ecosystem.config.js
pm2 startup
pm2 save

clear
echo
echo "¡PANEL DTUNNEL INSTALADO CON ÉXITO!"
echo "Dominio/IP configurado: $domain"

if [ "$is_domain" = true ]; then
  echo "Acceso seguro al panel via HAProxy: https://$domain:8443"
  echo "Acceso seguro a Prisma Studio: https://$domain:8443/studio/"
else
  echo "El panel se está ejecutando en el puerto: http://$domain:$porta"
  echo "Prisma Studio disponible en: http://$domain:5656"
fi

echo
echo "Escriba el comando para gestionar: pmenu"
echo "O use directamente: pupdate (para actualizar)"
echo
rm -f "$0"
