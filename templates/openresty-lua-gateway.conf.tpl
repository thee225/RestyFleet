server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    root {{WEB_ROOT}}/{{DOMAIN}};
    index index.php index.html index.htm;

    ssl_certificate {{OPENRESTY_CONF}}/ssl/{{DOMAIN}}/cert.pem;
    ssl_certificate_key {{OPENRESTY_CONF}}/ssl/{{DOMAIN}}/key.pem;

    include snippets/cloudflare-realip.conf;

    access_log logs/{{DOMAIN}}.access.log;
    error_log logs/{{DOMAIN}}.error.log warn;

    rewrite_by_lua_file {{OPENRESTY_LUA}}/redirect.lua;
    access_by_lua_file {{OPENRESTY_LUA}}/bot_guard.lua;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:{{PHP_FPM_SOCK}};
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
