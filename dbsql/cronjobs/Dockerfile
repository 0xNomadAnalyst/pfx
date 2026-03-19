FROM postgres:16-alpine

RUN apk add --no-cache bash

WORKDIR /app

COPY onyc_refresh.sh .

RUN chmod +x onyc_refresh.sh

# Default: main loop (continuous). Override with ONYC_SINGLE_RUN=1 or --once for one-shot.
ENV ONYC_SINGLE_RUN=0
CMD ["./onyc_refresh.sh"]
