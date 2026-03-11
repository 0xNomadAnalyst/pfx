FROM postgres:16-alpine

RUN apk add --no-cache bash

WORKDIR /app

COPY onyc_refresh.sh .
COPY onyc_backfill.sh .

RUN chmod +x onyc_refresh.sh onyc_backfill.sh

CMD ["./onyc_refresh.sh"]
