<script lang="ts">
  import { encode } from 'uqr';

  interface Props {
    /** What the code carries, usually a URL. */
    value: string;
    /** The accessible name of the picture. */
    label: string;
  }

  let { value, label }: Props = $props();

  // Dark modules on white with the quiet zone uqr adds, whatever the page theme: a scanner reads
  // dark-on-light.
  const qr = $derived(encode(value, { border: 2 }));
  const path = $derived(
    qr.data.flatMap((row, y) => row.flatMap((dark, x) => (dark ? ['M' + String(x) + ' ' + String(y) + 'h1v1h-1z'] : []))).join('')
  );
</script>

<svg role="img" aria-label={label} viewBox="0 0 {qr.size} {qr.size}" shape-rendering="crispEdges" class="h-48 w-48 rounded-md bg-white">
  <path d={path} fill="#000" />
</svg>
