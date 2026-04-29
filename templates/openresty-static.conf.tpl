server {
    listen 80;
    listen 443 ssl http2;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root {{WEB_ROOT}}/{{DOMAIN}};
    index index.html index.htm;

    ssl_certificate {{OPENRESTY_CONF}}/ssl/{{DOMAIN}}/cert.pem;
    ssl_certificate_key {{OPENRESTY_CONF}}/ssl/{{DOMAIN}}/key.pem;

    include snippets/cloudflare-realip.conf;

    access_log logs/{{DOMAIN}}.access.log;
    error_log logs/{{DOMAIN}}.error.log warn;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
