import { defineConfig } from 'vitepress'

// Published at picorubykaigi.org/adventure-board/ by the repository of that
// name (its workflow calls .github/workflows/build-guide.yml here).
// SITE_BASE overrides it (docker/compose.yml).
const base = process.env.SITE_BASE || '/adventure-board/'

// The console's own site (picorubykaigi.org/adventure-board-console/). Unset,
// the links go to console/ beside the guide, which is where `rake site:build`
// puts it for looking at locally. <ConsoleLink> reads the same variable.
const consoleUrl = process.env.VITE_CONSOLE_URL || '/console/'

export default defineConfig({
  lang: 'ja',
  title: 'Adventure Board',
  description: 'PicoRubyKaigi 2026 の基板 Adventure Board の使い方とチュートリアル',
  base,
  cleanUrls: true,
  lastUpdated: false,
  // Notes for whoever works on the site, not a page of it. guide/usb-midi.md
  // waits for the firmware that has USB MIDI built in (dev-docs/usb-midi/).
  srcExclude: ['README.md', 'guide/usb-midi.md'],

  // The console (sim/) is copied in after the build by `rake site:build`,
  // so VitePress does not know it is there.
  ignoreDeadLinks: [/^\/console\//],

  // The home page's button to the console is written as /console/ in its
  // frontmatter, which cannot read the environment.
  transformPageData(pageData) {
    const actions = pageData.frontmatter.hero?.actions
    if (!actions) return
    for (const action of actions) if (action.link === '/console/') action.link = consoleUrl
  },

  head: [
    // The fonts picorubykaigi.org and the console use (Google Fonts, OFL).
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    ['link', {
      rel: 'stylesheet',
      href: 'https://fonts.googleapis.com/css2?family=DotGothic16&family=Jersey+10&family=Zen+Kaku+Gothic+New:wght@400;500;700&display=swap'
    }]
  ],

  markdown: {
    // The code blocks are dark in both themes, as on picorubykaigi.org.
    theme: { light: 'one-dark-pro', dark: 'one-dark-pro' }
  },

  themeConfig: {
    nav: [
      { text: 'はじめに', link: '/guide/' },
      { text: 'チュートリアル', link: '/tutorial/' },
      { text: 'リファレンス', link: '/reference/library' },
      { text: 'コンソール', link: consoleUrl, target: '_blank' }
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'はじめに',
          items: [
            { text: 'Adventure Board とは', link: '/guide/' },
            { text: '基板の各部', link: '/guide/board' },
            { text: 'コンソールを使う', link: '/guide/console' },
            { text: 'R2P2のシェル', link: '/guide/shell' },
            { text: 'ファームウェアの書き込み', link: '/guide/firmware' }
            // { text: 'USB MIDI で鳴らす', link: '/guide/usb-midi' },  // 公開は USB MIDI 入りのファームのとき
          ]
        }
      ],
      '/tutorial/': [
        {
          text: 'チュートリアル',
          items: [
            { text: '進め方', link: '/tutorial/' },
            { text: '1. 1 ドット光らせる', link: '/tutorial/01-light' },
            { text: '2. 動かす', link: '/tutorial/02-loop' },
            { text: '3. 線と文字を描く', link: '/tutorial/03-draw' },
            { text: '4. ボタンで操作する', link: '/tutorial/04-buttons' },
            { text: '5. 音を鳴らす', link: '/tutorial/05-sound' },
            { text: '6. ゲームを作る', link: '/tutorial/06-game' },
            { text: '7. ブレッドボードで電子工作', link: '/tutorial/07-breadboard' },
            { text: '8. 作品にする', link: '/tutorial/08-app' }
          ]
        }
      ],
      '/reference/': [
        {
          text: 'リファレンス',
          items: [
            { text: 'ライブラリ', link: '/reference/library' },
            { text: 'ピンとコネクタ', link: '/reference/pins' }
          ]
        }
      ]
    },

    outline: { level: [2, 3], label: 'このページの内容' },
    docFooter: { prev: '前へ', next: '次へ' },
    darkModeSwitchLabel: '表示',
    lightModeSwitchTitle: 'ライトにする',
    darkModeSwitchTitle: 'ダークにする',
    sidebarMenuLabel: 'メニュー',
    returnToTopLabel: '上へ戻る',
    langMenuLabel: '言語',

    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '検索', buttonAriaLabel: '検索' },
          modal: {
            noResultsText: '見つかりませんでした',
            resetButtonTitle: '消す',
            footer: { selectText: '選ぶ', navigateText: '移動', closeText: '閉じる' }
          }
        }
      }
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/picorubykaigi/adventure-board-firmware' }
    ],

    footer: {
      message: '<a href="https://picorubykaigi.org/">PicoRubyKaigi 2026 Assemble</a>'
    }
  }
})
