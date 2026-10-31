import { defineConfig } from 'vite';

// Relative paths let the static build deploy under any subfolder, such as GitHub Pages.
export default defineConfig({ base: './' });
