FROM postgres:16-alpine

RUN apk add --no-cache bash

WORKDIR /app

COPY onyc_refresh.sh .

RUN chmod +x onyc_refresh.sh

CMD ["./onyc_refresh.sh"]
