FROM postgres:16-alpine

RUN apk add --no-cache bash

WORKDIR /app

COPY pfx/dbsql/cronjobs/onyc_refresh.sh .
COPY pfx/dbsql/cronjobs/onyc_backfill.sh .

RUN chmod +x onyc_refresh.sh onyc_backfill.sh

CMD ["./onyc_refresh.sh"]
