map $http_user_agent {{MOBILE_VAR}} {
    default 0;
    ~*(android|iphone|ipad|ipod|mobile|windows\ phone) 1;
}

map {{MOBILE_VAR}} {{DEVICE_ROOT_VAR}} {
    default {{WEB_ROOT}}/{{DOMAIN}}/pc;
    1 {{WEB_ROOT}}/{{DOMAIN}}/mobile;
}

server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root {{DEVICE_ROOT_VAR}};
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
