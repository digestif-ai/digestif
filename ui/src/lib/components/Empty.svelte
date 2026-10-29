<script lang="ts">
  interface Props {
    text: string;
  }

  let { text }: Props = $props();
</script>

<p class="dg-muted px-4 py-8 text-center text-sm">{text}</p>
