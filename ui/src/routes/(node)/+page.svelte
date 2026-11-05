<script lang="ts">
  import Command from '#lib/components/Command.svelte';
  import PageHeader from '#lib/components/PageHeader.svelte';
</script>

<PageHeader title="Your first note" />

<div class="dg-card p-4" data-testid="setup-continues">
  <p>Setup continues in your terminal: <Command command="~/.local/bin/digestif setup" /></p>
</div>
