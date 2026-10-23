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
      // Microservice targets are env-driven so the local demo (defaults) and
      // the AWS platform (ALB URLs) share one dev server. Local four-terminal
      // demo is UNCHANGED - the defaults are still the local services.
      // City tier: local tsx server OR the AWS ALB (export CITY_TARGET first)
      '/api/city': process.env.CITY_TARGET || 'http://localhost:4001',
      // User tier: local tsx server OR the AWS ALB (export USER_TARGET first)
      '/api/user': process.env.USER_TARGET || 'http://localhost:4002'
    }
  },

  build: {
    sourcemap: true
  }
});