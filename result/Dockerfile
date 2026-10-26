# ==============================================================================
# Dockerfile for Result Dashboard Service (Node.js / Express)
# ==============================================================================
FROM node:18-alpine

WORKDIR /app

# Cache package dependencies
COPY package*.json ./
RUN npm install --omit=dev

# Copy application code
COPY . .

EXPOSE 80

CMD ["node", "server.js"]
