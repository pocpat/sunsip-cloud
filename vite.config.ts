import { sentryVitePlugin } from "@sentry/vite-plugin";
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react(), sentryVitePlugin({
    org: "elena-i2",
    project: "sunsip",
    telemetry: false, 
  })],

  optimizeDeps: {
    exclude: ['lucide-react'],
  },

  server: {
    proxy: {
      // Microservice 1: city experience (weather / cocktail / image / landmark)
      '/api/city': 'http://localhost:4001',
      // Microservice 2: user & collection (auth / favourites / preferences)
      '/api/user': 'http://localhost:4002'
    }
  },

  build: {
    sourcemap: true
  }
});