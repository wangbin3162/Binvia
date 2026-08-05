<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from './api/client'
import type { OverviewResponse } from './api/types'
import OverviewView from './views/OverviewView.vue'
import ProvidersView from './views/ProvidersView.vue'
import LogsView from './views/LogsView.vue'
import KeysView from './views/KeysView.vue'
import SettingsView from './views/SettingsView.vue'

const tabs = ['概览', 'Provider', '请求日志', '网关 Keys', '设置'] as const
const activeTab = ref(0)
const needsLogin = ref(false)
const loginPassword = ref('')
const loginError = ref('')
const serverStatus = ref('loading')
const serverHost = ref('localhost')
const serverPort = ref(20427)
const version = ref('')
const toastMessage = ref('')
let toastTimer: ReturnType<typeof setTimeout> | null = null
let pollTimer: ReturnType<typeof setInterval> | null = null

function showToast(msg: string) {
  toastMessage.value = msg
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toastMessage.value = '' }, 3000)
}

async function doLogin() {
  loginError.value = ''
  const token = await api.login(loginPassword.value)
  if (token) {
    needsLogin.value = false
    showToast('登录成功')
    startPolling()
  } else {
    loginError.value = '密码错误'
  }
}

const overviewData = ref<OverviewResponse | null>(null)

async function fetchOverview(): Promise<boolean> {
  try {
    overviewData.value = await api.overview()
    if (overviewData.value) {
      serverStatus.value = overviewData.value.server.running ? 'running' : 'stopped'
      serverHost.value = overviewData.value.server.host
      serverPort.value = overviewData.value.server.port
    }
    return true
  } catch {
    return false
  }
}

function startPolling() {
  if (pollTimer) clearInterval(pollTimer)
  void fetchOverview()
  pollTimer = setInterval(fetchOverview, 2000)
}

onMounted(async () => {
  if (api.isLoggedIn()) {
    needsLogin.value = false
    startPolling()
  } else {
    try {
      needsLogin.value = !(await fetchOverview())
      if (!needsLogin.value) startPolling()
    } catch {
      needsLogin.value = true
    }
  }
})

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer)
})
</script>

<template>
  <div class="min-h-screen bg-[var(--color-bg)]">
    <!-- 登录遮罩 -->
    <div v-if="needsLogin" class="fixed inset-0 flex items-center justify-center bg-[var(--color-bg)] z-50">
      <div class="bg-white p-8 rounded-xl shadow-lg w-80">
        <h2 class="text-lg font-semibold mb-2">Binvia 管理面板</h2>
        <p class="text-sm text-[var(--color-text-secondary)] mb-4">请输入管理员密码</p>
        <input
          v-model="loginPassword"
          type="password"
          placeholder="密码"
          class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg mb-3 text-sm outline-none focus:border-[var(--color-blue)]"
          @keyup.enter="doLogin"
        />
        <p v-if="loginError" class="text-xs text-[var(--color-red)] mb-2">{{ loginError }}</p>
        <button
          class="w-full py-2 bg-[var(--color-blue)] text-white rounded-lg text-sm font-medium hover:opacity-90"
          @click="doLogin"
        >登录</button>
      </div>
    </div>

    <!-- 顶栏 -->
    <header class="bg-white border-b border-[var(--color-border)] px-6 py-3 flex items-center gap-4">
      <div class="flex items-center gap-2">
        <span class="w-2 h-2 rounded-full" :class="{
          'bg-[var(--color-green)]': serverStatus === 'running',
          'bg-[var(--color-red)]': serverStatus === 'stopped',
          'bg-[var(--color-amber)]': serverStatus === 'loading',
        }"></span>
        <span class="font-semibold text-sm">Binvia</span>
      </div>
      <span class="text-xs text-[var(--color-text-secondary)]">
        http://{{ serverHost }}:{{ serverPort }}
      </span>
      <span class="text-xs text-[var(--color-text-secondary)] ml-auto">{{ version }}</span>
    </header>

    <!-- Tab 导航 -->
    <div class="bg-white border-b border-[var(--color-border)] px-6 flex gap-6">
      <button
        v-for="(tab, i) in tabs"
        :key="tab"
        class="py-3 text-sm border-b-2 transition-colors"
        :class="activeTab === i
          ? 'border-[var(--color-blue)] text-[var(--color-blue)] font-medium'
          : 'border-transparent text-[var(--color-text-secondary)] hover:text-[var(--color-text)]'"
        @click="activeTab = i"
      >{{ tab }}</button>
    </div>

    <!-- 内容区 -->
    <main class="p-6 max-w-6xl mx-auto">
      <OverviewView v-if="activeTab === 0" :overview="overviewData" />
      <ProvidersView v-else-if="activeTab === 1" />
      <LogsView v-else-if="activeTab === 2" />
      <KeysView v-else-if="activeTab === 3" />
      <SettingsView v-else-if="activeTab === 4" />
    </main>

    <!-- Toast -->
    <div
      v-if="toastMessage"
      class="fixed bottom-6 right-6 bg-[var(--color-text)] text-white px-4 py-2 rounded-lg text-sm shadow-lg transition-opacity"
    >{{ toastMessage }}</div>
  </div>
</template>
