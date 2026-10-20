<script setup lang="ts">
import { computed } from "vue";
import MarkdownIt from "markdown-it";

const props = defineProps<{ text: string }>();
// 模型输出只作为 Markdown 内容：禁止原始 HTML 和远程图片。
const markdown = new MarkdownIt({
  html: false,
  linkify: false,
  breaks: true,
}).disable("image");
const rendered = computed(() => markdown.render(props.text));
</script>

<template>
  <div class="markdown" v-html="rendered"></div>
</template>
