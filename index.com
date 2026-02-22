import React, { useState, useEffect, useCallback } from 'react';

// ==========================================
// オーディオエンジン (Web Audio APIによるピコピコ音合成)
// ==========================================
let audioCtx = null;
let bgmTimer = null;
let currentBGMType = null;
let currentBGMStep = 0;
let nextBGMTime = 0;

const initAudio = () => {
  if (!audioCtx) {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  }
  if (audioCtx.state === 'suspended') {
    audioCtx.resume();
  }
};

// 単音を鳴らすヘルパー
const playTone = (freq, type, duration, vol = 0.1) => {
  if (!audioCtx) return;
  const osc = audioCtx.createOscillator();
  const gain = audioCtx.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(freq, audioCtx.currentTime);
  gain.gain.setValueAtTime(vol, audioCtx.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + duration);
  osc.connect(gain);
  gain.connect(audioCtx.destination);
  osc.start();
  osc.stop(audioCtx.currentTime + duration);
};

// 効果音 (SE)
const playSE = (type) => {
  if (!audioCtx) return;
  const now = audioCtx.currentTime;
  
  if (type === 'attack') {
    // 攻撃（ザシュッ）
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = 'square';
    osc.frequency.setValueAtTime(800, now);
    osc.frequency.exponentialRampToValueAtTime(50, now + 0.15);
    gain.gain.setValueAtTime(0.2, now);
    gain.gain.exponentialRampToValueAtTime(0.01, now + 0.15);
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.start();
    osc.stop(now + 0.15);
  } else if (type === 'correct') {
    // 正解（ピロリロリン）
    setTimeout(() => playTone(523.25, 'square', 0.1, 0.1), 0);
    setTimeout(() => playTone(659.25, 'square', 0.1, 0.1), 100);
    setTimeout(() => playTone(783.99, 'square', 0.2, 0.1), 200);
  } else if (type === 'wrong') {
    // 不正解（ブブー）
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = 'sawtooth';
    osc.frequency.setValueAtTime(150, now);
    gain.gain.setValueAtTime(0.2, now);
    gain.gain.setValueAtTime(0.2, now + 0.2);
    gain.gain.linearRampToValueAtTime(0.01, now + 0.3);
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.start();
    osc.stop(now + 0.3);
  } else if (type === 'encounter') {
    // エンカウント（ピロピロピロ）
    for(let i=0; i<4; i++) {
      setTimeout(() => playTone(880, 'square', 0.05, 0.1), i*100);
      setTimeout(() => playTone(830.6, 'square', 0.05, 0.1), i*100 + 50);
    }
  } else if (type === 'clear') {
    // 全クリ（ファンファーレ）
    setTimeout(() => playTone(523.25, 'square', 0.15, 0.1), 0);
    setTimeout(() => playTone(523.25, 'square', 0.15, 0.1), 150);
    setTimeout(() => playTone(523.25, 'square', 0.15, 0.1), 300);
    setTimeout(() => playTone(659.25, 'square', 0.4, 0.1), 450);
  } else if (type === 'win') {
    // 県クリア・勝利（レベルアップ風）
    setTimeout(() => playTone(523.25, 'square', 0.1, 0.1), 0);
    setTimeout(() => playTone(587.33, 'square', 0.1, 0.1), 100);
    setTimeout(() => playTone(659.25, 'square', 0.1, 0.1), 200);
    setTimeout(() => playTone(698.46, 'square', 0.1, 0.1), 300);
    setTimeout(() => playTone(783.99, 'square', 0.4, 0.1), 400);
  } else if (type === 'step') {
    // 歩く音（ザッ）
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = 'triangle';
    osc.frequency.setValueAtTime(120, now);
    osc.frequency.exponentialRampToValueAtTime(20, now + 0.05);
    gain.gain.setValueAtTime(0.05, now);
    gain.gain.exponentialRampToValueAtTime(0.01, now + 0.05);
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.start();
    osc.stop(now + 0.05);
  }
};

// BGM (周波数と長さの配列)
const BGM_DATA = {
  title: [
    [392, 0.2], [392, 0.2], [392, 0.2], [523.25, 0.6], [392, 0.6], [523.25, 0.4], [587.33, 0.4], [659.25, 0.8],
    [0, 0.2], [523.25, 0.2], [587.33, 0.2], [659.25, 0.2], [698.46, 0.4], [659.25, 0.4], [587.33, 0.4], [523.25, 0.4],
    [587.33, 0.8], [0, 0.4]
  ],
  field: [
    [261.63, 0.25], [329.63, 0.25], [392.00, 0.25], [329.63, 0.25],
    [293.66, 0.25], [349.23, 0.25], [440.00, 0.25], [349.23, 0.25],
    [261.63, 0.25], [329.63, 0.25], [392.00, 0.25], [523.25, 0.25],
    [440.00, 0.25], [392.00, 0.25], [349.23, 0.25], [293.66, 0.25]
  ],
  battle: [
    [130.81, 0.15], [130.81, 0.15], [146.83, 0.15], [130.81, 0.15], 
    [130.81, 0.15], [155.56, 0.15], [130.81, 0.15], [146.83, 0.15],
    [164.81, 0.15], [164.81, 0.15], [185.00, 0.15], [164.81, 0.15],
    [164.81, 0.15], [196.00, 0.15], [164.81, 0.15], [185.00, 0.15]
  ]
};

const stopBGM = () => {
  currentBGMType = null;
  if (bgmTimer) {
    clearTimeout(bgmTimer);
    bgmTimer = null;
  }
};

const scheduleBGM = () => {
  if (!currentBGMType || !audioCtx) return;
  
  while (nextBGMTime < audioCtx.currentTime + 0.1) {
    const melody = BGM_DATA[currentBGMType];
    const [freq, duration] = melody[currentBGMStep];
    
    if (freq > 0) {
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = currentBGMType === 'battle' ? 'sawtooth' : 'square';
      osc.frequency.setValueAtTime(freq, nextBGMTime);
      gain.gain.setValueAtTime(0.03, nextBGMTime); // BGMは控えめの音量
      gain.gain.exponentialRampToValueAtTime(0.001, nextBGMTime + duration * 0.9);
      osc.connect(gain);
      gain.connect(audioCtx.destination);
      osc.start(nextBGMTime);
      osc.stop(nextBGMTime + duration);
    }
    
    nextBGMTime += duration;
    currentBGMStep = (currentBGMStep + 1) % melody.length;
  }
  bgmTimer = setTimeout(scheduleBGM, 25);
};

const playBGM = (type) => {
  if (!audioCtx) return;
  stopBGM();
  currentBGMType = type;
  currentBGMStep = 0;
  nextBGMTime = audioCtx.currentTime + 0.1;
  scheduleBGM();
};


// ==========================================
// 1. ゲームデータ（47都道府県 × 各6問）
// ==========================================
const prefRawData = [
  [1, '北海道', 71, 3, [['道庁所在地は？','札幌市','函館市','旭川市','小樽市'],['世界自然遺産に登録されている半島は？','知床半島','積丹半島','根室半島','渡島半島'],['マリモが生息する有名な湖は？','阿寒湖','摩周湖','洞爺湖','屈斜路湖'],['北海道の先住民族は？','アイヌ','琉球民族','ウィルタ','ニヴフ'],['北海道が生産量日本一の野菜は？','じゃがいも','キャベツ','トマト','ナス'],['有名な冬のお祭りは？','さっぽろ雪まつり','かまくら祭','なまはげ','ねぶた祭']]],
  [2, '青森県', 66, 7, [['県庁所在地は？','青森市','弘前市','八戸市','むつ市'],['有名なお祭りは？','ねぶた祭','竿燈まつり','七夕まつり','花笠まつり'],['生産量日本一の果物は？','りんご','みかん','もも','ぶどう'],['世界自然遺産の山地は？','白神山地','八甲田山','恐山','岩木山'],['北海道と繋がるトンネルは？','青函トンネル','関門トンネル','津軽トンネル','アクアライン'],['有名なマグロの産地は？','大間','石巻','焼津','勝浦']]],
  [3, '岩手県', 66, 9, [['県庁所在地は？','盛岡市','花巻市','北上市','奥州市'],['世界遺産の金色堂があるお寺は？','中尊寺','毛越寺','瑞巌寺','立石寺'],['次々とそばをお椀に入れる郷土料理は？','わんこそば','戸隠そば','出雲そば','越前そば'],['複雑に入り組んだ海岸地形を何という？','リアス海岸','砂浜海岸','サンゴ礁海岸','フィヨルド'],['伝統工芸品の鉄器といえば？','南部鉄器','燕三条鉄器','高岡銅器','伊万里焼'],['「銀河鉄道の夜」の作者は？','宮沢賢治','太宰治','石川啄木','夏目漱石']]],
  [4, '宮城県', 65, 11, [['県庁所在地は？','仙台市','石巻市','大崎市','気仙沼市'],['初代仙台藩主の戦国武将は？','伊達政宗','上杉謙信','武田信玄','毛利元就'],['名物の肉料理といえば？','牛タン','ジンギスカン','豚の角煮','馬刺し'],['日本三景の一つである島々は？','松島','宮島','天橋立','江の島'],['有名な夏のお祭りは？','仙台七夕まつり','阿波おどり','よさこい祭り','祇園祭'],['三陸沖の世界三大漁場の一つは？','金華山沖','銚子沖','根室沖','玄界灘']]],
  [5, '秋田県', 64, 9, [['県庁所在地は？','秋田市','横手市','大館市','能代市'],['大晦日に家々を回る伝統行事は？','なまはげ','かまくら','竿燈まつり','さんさ踊り'],['ご飯をすりつぶして串に刺した郷土料理は？','きりたんぽ','だまこもち','ずんだ餅','笹かまぼこ'],['日本で一番深い湖は？','田沢湖','琵琶湖','摩周湖','猪苗代湖'],['天然記念物に指定されている日本犬は？','秋田犬','柴犬','甲斐犬','土佐犬'],['有名な夏のお祭りは？','秋田竿燈まつり','ねぶた祭','花笠まつり','七夕まつり']]],
  [6, '山形県', 63, 11, [['県庁所在地は？','山形市','鶴岡市','酒田市','米沢市'],['生産量日本一の果物は？','さくらんぼ','りんご','もも','ぶどう'],['樹氷で有名な温泉地・スキー場は？','蔵王','草津','白馬','ニセコ'],['県内を流れる「五月雨を…」で詠まれた川は？','最上川','信濃川','阿賀野川','利根川'],['生産量日本一を誇るボードゲームの道具は？','将棋駒','囲碁石','麻雀牌','花札'],['花笠を手に踊る夏のお祭りは？','花笠まつり','さんさ踊り','よさこい','阿波おどり']]],
  [7, '福島県', 63, 12, [['県庁所在地は？','福島市','郡山市','いわき市','会津若松市'],['日本で4番目に広い湖は？','猪苗代湖','琵琶湖','霞ヶ浦','サロマ湖'],['日本三大ラーメンの一つとされるのは？','喜多方ラーメン','博多ラーメン','札幌ラーメン','和歌山ラーメン'],['黄熱病の研究で知られる福島出身の偉人は？','野口英世','北里柴三郎','福沢諭吉','渋沢栄一'],['白虎隊で有名な会津若松のお城は？','鶴ヶ城','青葉城','弘前城','白石城'],['首が揺れる赤い牛の郷土玩具は？','赤べこ','起き上がり小法師','こけし','だるま']]],
  [8, '茨城県', 64, 14, [['県庁所在地は？','水戸市','つくば市','日立市','土浦市'],['名物として知られる大豆の発酵食品は？','納豆','味噌','醤油','豆腐'],['日本三名園の一つである水戸の庭園は？','偕楽園','兼六園','後楽園','栗林公園'],['日本で2番目に広い湖は？','霞ヶ浦','琵琶湖','サロマ湖','猪苗代湖'],['宇宙航空研究開発機構(JAXA)がある市は？','つくば市','水戸市','日立市','鹿嶋市'],['ギネス記録を持つ青銅製の巨大仏像は？','牛久大仏','鎌倉大仏','奈良の大仏','高岡大仏']]],
  [9, '栃木県', 62, 14, [['県庁所在地は？','宇都宮市','小山市','栃木市','足利市'],['徳川家康を祀る世界遺産の神社は？','日光東照宮','明治神宮','伊勢神宮','出雲大社'],['「とちおとめ」で知られる生産量日本一の果物は？','いちご','もも','ぶどう','メロン'],['宇都宮市が消費量日本一を争う食べ物は？','餃子','うどん','ラーメン','カレー'],['日本三大名瀑の一つである滝は？','華厳の滝','那智の滝','袋田の滝','白糸の滝'],['かつて公害事件が起きた有名な銅山は？','足尾銅山','別子銅山','生野銀山','石見銀山']]],
  [10, '群生県', 61, 14, [['県庁所在地は？','前橋市','高崎市','太田市','伊勢崎市'],['湯畑で有名な日本三名泉の一つは？','草津温泉','有馬温泉','下呂温泉','別府温泉'],['生産量日本一のイモ類加工食品は？','こんにゃく','ところてん','寒天','しらたき'],['世界遺産に登録された明治時代の絹糸工場は？','富岡製糸場','八幡製鉄所','長崎造船所','三池炭鉱'],['高崎市が生産量日本一を誇る縁起物は？','だるま','招き猫','赤べこ','こけし'],['嬬恋村で栽培が盛んな高原野菜は？','キャベツ','レタス','白菜','大根']]],
  [11, '埼玉県', 61, 15, [['県庁所在地は？','さいたま市','川口市','川越市','所沢市'],['名物の硬いおせんべいといえば？','草加せんべい','ぬれせんべい','南部せんべい','瓦せんべい'],['日本三大曳山祭に数えられるお祭りは？','秩父夜祭','祇園祭','高山祭','ねぶた祭'],['深谷市が生産量日本一を誇る野菜は？','ねぎ','たまねぎ','にんじん','じゃがいも'],['さいたま市にある交通系の巨大博物館は？','鉄道博物館','リニア・鉄道館','京都鉄道博物館','地下鉄博物館'],['新1万円札の顔となった深谷市出身の人物は？','渋沢栄一','福沢諭吉','津田梅子','北里柴三郎']]],
  [12, '千葉県', 63, 16, [['県庁所在地は？','千葉市','船橋市','松戸市','市川市'],['生産量日本一の豆類といえば？','落花生','大豆','小豆','そら豆'],['日本の玄関口である国際空港は？','成田国際空港','羽田空港','関西国際空港','中部国際空港'],['太平洋に面した約66kmの砂浜海岸は？','九十九里浜','湘南海岸','鳥取砂丘','千里浜'],['千葉県の大部分を占める半島は？','房総半島','三浦半島','伊豆半島','紀伊半島'],['浦安市にある有名なテーマパークは？','ディズニーリゾート','USJ','ハウステンボス','富士急ハイランド']]],
  [13, '東京都', 61, 16, [['都庁所在地は？','新宿区','渋谷区','千代田区','港区'],['高さ634mの日本一高い電波塔は？','スカイツリー','東京タワー','通天閣','福岡タワー'],['浅草寺の入り口にある有名な門は？','雷門','桜田門','半蔵門','羅生門'],['世界自然遺産に登録されている島々は？','小笠原諸島','伊豆諸島','千島列島','南西諸島'],['鉄板で小麦粉の生地と具を焼く郷土料理は？','もんじゃ焼き','お好み焼き','たこ焼き','チヂミ'],['徳川家康が開いた武家政権は？','江戸幕府','鎌倉幕府','室町幕府','明治新政府']]],
  [14, '神奈川県', 60, 17, [['県庁所在地は？','横浜市','川崎市','相模原市','横須賀市'],['高徳院にある国宝の巨大な仏像は？','鎌倉大仏','奈良の大仏','牛久大仏','高岡大仏'],['箱根にある正月の駅伝で有名な湖は？','芦ノ湖','河口湖','山中湖','諏訪湖'],['日本最大の中華街がある都市は？','横浜市','神戸市','長崎市','大阪市'],['名物として知られる点心(豚肉の包み蒸し)は？','しゅうまい','餃子','肉まん','小籠包'],['観覧車や赤レンガ倉庫がある臨海エリアは？','みなとみらい','お台場','ハーバーランド','ベイサイドプレイス']]],
  [15, '新潟県', 60, 13, [['県庁所在地は？','新潟市','長岡市','上越市','三条市'],['生産量日本一を誇る代表的な農作物は？','お米','小麦','とうもろこし','大豆'],['かつて金山で栄えた日本海最大の島は？','佐渡島','淡路島','小豆島','対馬'],['日本で一番長い川は？','信濃川','利根川','石狩川','天塩川'],['米菓として有名な三日月型のあられは？','柿の種','草加せんべい','ぬれせんべい','歌舞伎揚'],['特別天然記念物に指定されている鳥は？','トキ','コウノトリ','ライチョウ','タンチョウ']]],
  [16, '富山県', 57, 16, [['県庁所在地は？','富山市','高岡市','射水市','南砺市'],['高さ日本一を誇る巨大なアーチ式ダムは？','黒部ダム','宮ヶ瀬ダム','八ッ場ダム','徳山ダム'],['春に青白く光ることで知られるイカは？','ホタルイカ','スルメイカ','ヤリイカ','ダイオウイカ'],['生産量日本一を誇る春の球根花は？','チューリップ','ヒマワリ','カーネーション','バラ'],['江戸時代から続く「配置販売」の文化は？','越中富山の薬売り','近江商人','伊勢商人','薩摩の薬売り'],['世界遺産に登録された急勾配の屋根の集落は？','五箇山の合掌造り','白川郷','大内宿','美山町']]],
  [17, '石川県', 55, 17, [['県庁所在地は？','金沢市','白山市','小松市','加賀市'],['日本三名園の一つである金沢の庭園は？','兼六園','偕楽園','後楽園','栗林公園'],['色鮮やかな絵付けが特徴の伝統的な陶磁器は？','九谷焼','有田焼','備前焼','信楽焼'],['日本海に突き出た形の半島は？','能登半島','房総半島','伊豆半島','紀伊半島'],['江戸時代に金沢を治めた前田家の石高は？','加賀百万石','仙台六十二万石','薩摩七十七万石','長州三十六万石'],['高級魚として知られる「アカムツ」の別名は？','のどぐろ','きんき','クエ','トラフグ']]],
  [18, '福井県', 55, 18, [['県庁所在地は？','福井市','坂井市','越前市','敦賀市'],['勝山市にある世界有数の博物館は？','恐竜博物館','鉄道博物館','国立科学博物館','宇宙博物館'],['冬の味覚として有名なブランドガニは？','越前ガニ','松葉ガニ','タラバガニ','毛ガニ'],['日本海の荒波が削り出した柱状の断崖絶壁は？','東尋坊','親不知','千畳敷','浄土ヶ浜'],['鯖江市が国内生産の9割を占める製品は？','メガネフレーム','万年筆','ランドセル','腕時計'],['リアス海岸が広がる県南部の湾は？','若狭湾','富山湾','駿河湾','相模湾']]],
  [19, '山梨県', 59, 16, [['県庁所在地は？','甲府市','富士吉田市','甲斐市','南アルプス市'],['標高3,776mの日本一高い山は？','富士山','北岳','奥穂高岳','槍ヶ岳'],['生産量日本一の果物は？','ぶどう','りんご','みかん','いちご'],['平打ち麺を野菜と味噌で煮込んだ郷土料理は？','ほうとう','吉田のうどん','きしめん','ひっつみ'],['「風林火山」の旗印で知られる戦国武将は？','武田信玄','上杉謙信','徳川家康','織田信長'],['富士山の麓にある５つの湖の総称は？','富士五湖','三方五湖','裏磐梯三湖','知床五湖']]],
  [20, '長野県', 58, 15, [['県庁所在地は？','長野市','松本市','上田市','飯田市'],['「牛に引かれて…」の言葉で有名な寺院は？','善光寺','清水寺','浅草寺','中尊寺'],['名物として知られる麺類は？','信州そば','讃岐うどん','きしめん','そうめん'],['飛騨・木曽・赤石の3つの山脈の総称は？','日本アルプス','奥羽山脈','日高山脈','鈴鹿山脈'],['川上村などで栽培が盛んな高原野菜は？','レタス','キャベツ','白菜','大根'],['避暑地として全国的に有名なリゾート地は？','軽井沢','那須','富良野','箱根']]],
  [21, '岐阜県', 58, 17, [['県庁所在地は？','岐阜市','大垣市','各務原市','高山市'],['世界遺産に登録された合掌造りの集落は？','白川郷','五箇山','大内宿','妻籠宿'],['県内で育てられる有名な黒毛和牛は？','飛騨牛','松阪牛','神戸牛','近江牛'],['長良川で夏の夜に行われる伝統的な漁法は？','鵜飼','地引き網','一本釣り','定置網'],['「北アルプス」と呼ばれる山脈の正式名称は？','飛騨山脈','木曽山脈','赤石山脈','奥羽山脈'],['関市で生産が盛んな金属製品は？','刃物','洋食器','南部鉄器','銅器']]],
  [22, '静岡県', 59, 18, [['県庁所在地は？','静岡市','浜松市','富士市','沼津市'],['生産量日本一を誇る飲み物は？','お茶','コーヒー','牛乳','リンゴジュース'],['うなぎの養殖で有名な県西部の湖は？','浜名湖','琵琶湖','霞ヶ浦','サロマ湖'],['山梨県と県境を接する日本一高い山は？','富士山','北岳','赤石岳','槍ヶ岳'],['浜名湖名物として知られる魚は？','うなぎ','マグロ','カツオ','サケ'],['浜松市が世界的なシェアを持つ楽器は？','ピアノ','ギター','バイオリン','トランペット']]],
  [23, '愛知県', 58, 18, [['県庁所在地は？','名古屋市','豊田市','一宮市','岡崎市'],['屋根の上の金のシャチホコで有名なお城は？','名古屋城','大阪城','姫路城','熊本城'],['県内で最も盛んな製造業は？','自動車産業','造船業','鉄鋼業','電子部品'],['うなぎの蒲焼を細かく刻んでご飯に乗せた料理は？','ひつまぶし','うな重','うな丼','白焼き'],['名古屋城の屋根に乗っている架空の生き物は？','しゃちほこ','シーサー','狛犬','竜'],['豊田市に本社を置く世界的な自動車メーカーは？','トヨタ','ホンダ','日産','マツダ']]],
  [24, '三重県', 57, 19, [['県庁所在地は？','津市','四日市市','伊勢市','鈴鹿市'],['天照大御神を祀る日本を代表する神社は？','伊勢神宮','出雲大社','明治神宮','伏見稲荷大社'],['日本三大和牛の一つとされる高級牛肉は？','松阪牛','神戸牛','米沢牛','近江牛'],['英虞湾などで養殖が盛んな宝石は？','真珠','サンゴ','琥珀','ヒスイ'],['F1日本グランプリが開催されるサーキットは？','鈴鹿サーキット','富士スピードウェイ','ツインリンクもてぎ','菅生'],['志摩半島に見られる複雑に入り組んだ海岸は？','リアス海岸','砂浜海岸','サンゴ礁','フィヨルド']]],
  [25, '滋賀県', 56, 18, [['県庁所在地は？','大津市','草津市','長浜市','彦根市'],['県の面積の約6分の1を占める日本最大の湖は？','琵琶湖','霞ヶ浦','サロマ湖','猪苗代湖'],['タヌキの置物で有名な焼き物は？','信楽焼','備前焼','有田焼','九谷焼'],['彦根城の有名なゆるキャラは？','ひこにゃん','くまモン','ふなっしー','バリィさん'],['県内で育てられる有名な黒毛和牛は？','近江牛','松阪牛','神戸牛','飛騨牛'],['最澄が開いた天台宗の総本山・比叡山にあるお寺は？','延暦寺','金剛峯寺','東大寺','法隆寺']]],
  [26, '京都府', 55, 19, [['府庁所在地は？','京都市','宇治市','亀岡市','舞鶴市'],['足利義満が建てた金箔張りの建物のお寺は？','金閣寺','銀閣寺','清水寺','平安神宮'],['「清水の舞台から飛び降りる」で有名なお寺は？','清水寺','金閣寺','東寺','南禅寺'],['ニッキの香りがする琴の形の和菓子は？','八ツ橋','もみじ饅頭','ういろう','カステラ'],['7月に1ヶ月間行われる日本三大祭りの一つは？','祇園祭','天神祭','神田祭','ねぶた祭'],['宇治市周辺で生産される有名なお茶は？','宇治茶','静岡茶','狭山茶','八女茶']]],
  [27, '大阪府', 55, 20, [['府庁所在地は？','大阪市','堺市','東大阪市','豊中市'],['小麦粉の生地にタコを入れて丸く焼いた食べ物は？','たこ焼き','お好み焼き','明石焼き','もんじゃ焼き'],['豊臣秀吉が築いたお城は？','大阪城','名古屋城','姫路城','江戸城'],['新世界にある「天に通じる高い建物」という意味の塔は？','通天閣','東京タワー','京都タワー','神戸ポートタワー'],['大阪が本場とされる話芸文化は？','お笑い・漫才','歌舞伎','能・狂言','落語'],['堺市にある日本最大の前方後円墳は？','仁徳天皇陵','応神天皇陵','高松塚古墳','キトラ古墳']]],
  [28, '兵庫県', 53, 20, [['県庁所在地は？','神戸市','姫路市','西宮市','尼崎市'],['白鷺城とも呼ばれる世界遺産のお城は？','姫路城','大阪城','松本城','彦根城'],['世界的に有名なブランド牛肉は？','神戸牛','松阪牛','近江牛','米沢牛'],['女性だけで構成される有名なミュージカル劇団は？','宝塚歌劇団','劇団四季','OSK日本歌劇団','わらび座'],['本州と淡路島を結ぶ世界最長クラスの吊り橋は？','明石海峡大橋','瀬戸大橋','しまなみ海道','レインボーブリッジ'],['高校野球の全国大会が行われる球場は？','甲子園球場','東京ドーム','神宮球場','福岡PayPayドーム']]],
  [29, '奈良県', 56, 20, [['県庁所在地は？','奈良市','橿原市','生駒市','大和郡山市'],['大仏で有名な世界遺産のお寺は？','東大寺','法隆寺','興福寺','薬師寺'],['奈良公園にたくさんいて、神の使いとされる動物は？','鹿','猿','キツネ','ウサギ'],['春には桜が山全体を覆う名所は？','吉野山','嵐山','高尾山','富士山'],['聖徳太子が建てた世界最古の木造建築のお寺は？','法隆寺','東大寺','唐招提寺','飛鳥寺'],['塩漬けの鯖などを柿の葉で包んだお寿司は？','柿の葉寿司','ます寿司','なれずし','ばってら']]],
  [30, '和歌山県', 54, 21, [['県庁所在地は？','和歌山市','田辺市','橋本市','紀の川市'],['生産量日本一を誇る柑橘類は？','みかん','りんご','もも','ぶどう'],['空海（弘法大師）が開いた真言宗の総本山は？','高野山','比叡山','恐山','身延山'],['世界遺産「紀伊山地の霊場と参詣道」がある山地は？','紀伊山地','飛騨山脈','奥羽山脈','四国山地'],['南高梅などで知られる生産量日本一の果実は？','梅','柿','梨','キウイ'],['パンダの飼育数で日本一のテーマパークは？','アドベンチャーワールド','上野動物園','東山動植物園','旭山動物園']]],
  [31, '鳥取県', 51, 21, [['県庁所在地は？','鳥取市','米子市','倉吉市','境港市'],['日本最大級の起伏を持つ海岸砂丘は？','鳥取砂丘','中田島砂丘','吹上浜','九十九里浜'],['「二十世紀」などの品種で知られる特産果物は？','梨','りんご','もも','ぶどう'],['境港市出身の作者が描いた妖怪の漫画は？','ゲゲゲの鬼太郎','名探偵コナン','ドラえもん','ワンピース'],['冬の味覚として有名なブランドガニは？','松葉ガニ','越前ガニ','タラバガニ','毛ガニ'],['砂丘の横で栽培される特産の野菜は？','らっきょう','ねぎ','たまねぎ','にんにく']]],
  [32, '島根県', 48, 22, [['県庁所在地は？','松江市','出雲市','浜田市','益田市'],['縁結びの神様として有名な神社は？','出雲大社','伊勢神宮','厳島神社','伏見稲荷大社'],['宍道湖でよく採れる特産の貝は？','しじみ','あさり','はまぐり','ホタテ'],['世界遺産に登録されたかつて日本最大の銀山は？','石見銀山','生野銀山','佐渡金山','別子銅山'],['島根半島の北の日本海に浮かぶ島々は？','隠岐諸島','五島列島','小笠原諸島','奄美群島'],['割子という丸い漆器に盛って食べる郷土料理は？','出雲そば','わんこそば','戸隠そば','信州そば']]],
  [33, '岡山県', 50, 23, [['県庁所在地は？','岡山市','倉敷市','津山市','総社市'],['きびだんごを持ってお供を連れた昔話の主人公は？','桃太郎','金太郎','浦島太郎','一寸法師'],['「マスカット・オブ・アレキサンドリア」といえば何の果物？','ぶどう','もも','メロン','いちご'],['本州と四国を鉄道と道路で結ぶ橋は？','瀬戸大橋','明石海峡大橋','しまなみ海道','関門橋'],['日本三名園の一つである岡山の庭園は？','後楽園','兼六園','偕楽園','栗林公園'],['白壁の蔵屋敷が立ち並ぶ倉敷市の観光地は？','美観地区','ひがし茶屋街','祇園','角館']]],
  [34, '広島県', 48, 24, [['県庁所在地は？','広島市','福山市','呉市','東広島市'],['海の中に立つ赤い大鳥居で有名な世界遺産の神社は？','厳島神社','出雲大社','伏見稲荷大社','春日大社'],['もみじの葉の形をしたカステラ生地の和菓子は？','もみじ饅頭','八ツ橋','ういろう','きびだんご'],['生地・キャベツ・麺などを重ねて焼く粉ものは？','お好み焼き','たこ焼き','もんじゃ焼き','チヂミ'],['生産量日本一を誇る海のミルクと呼ばれる貝は？','牡蠣','ホタテ','アワビ','サザエ'],['平和への願いを込めて保存されている世界遺産は？','原爆ドーム','平和祈念像','ひめゆりの塔','知覧特攻平和会館']]],
  [35, '山口県', 44, 25, [['県庁所在地は？','山口市','下関市','宇部市','周南市'],['毒を持つが高級魚として知られ、下関で水揚げされる魚は？','ふぐ','タイ','ヒラメ','アンコウ'],['日本最大級のカルスト台地・秋吉台の地下にある鍾乳洞は？','秋芳洞','龍泉洞','玉泉洞','あぶくま洞'],['岩国市にある木造の5連アーチ橋は？','錦帯橋','眼鏡橋','かずら橋','日本橋'],['幕末に松下村塾を開き、多くの志士を育てた人物は？','吉田松陰','坂本龍馬','西郷隆盛','高杉晋作'],['関門海峡に面した山口県最大の都市は？','下関市','山口市','宇部市','岩国市']]],
  [36, '徳島県', 49, 29, [['県庁所在地は？','徳島市','阿南市','鳴門市','吉野川市'],['「踊る阿呆に見る阿呆」の掛け声で有名な夏祭りは？','阿波おどり','よさこい祭り','ねぶた祭','祇園祭'],['鳴門海峡で発生する激しい潮流現象は？','鳴門の渦潮','関門の渦潮','津軽の渦潮','玄界灘の渦潮'],['徳島県特産の、香りが良く酸味が強い柑橘類は？','すだち','かぼす','ゆず','シークワーサー'],['弘法大師ゆかりの88の寺院を巡る巡礼を何という？','四国八十八ヶ所','西国三十三所','秩父三十四箇所','坂東三十三箇所'],['「四国三郎」の異名を持つ四国一の大河は？','吉野川','四万十川','仁淀川','物部川']]],
  [37, '香川県', 48, 28, [['県庁所在地は？','高松市','丸亀市','三豊市','観音寺市'],['消費量日本一で、別名「うどん県」と呼ばれる理由は？','うどん','そば','ラーメン','そうめん'],['オリーブの栽培で有名な瀬戸内海で2番目に大きな島は？','小豆島','淡路島','直島','大三島'],['香川県特産の、平和の象徴とされる植物は？','オリーブ','みかん','レモン','すだち'],['「こんぴらさん」の愛称で親しまれる長い石段のある神社は？','金刀比羅宮','厳島神社','出雲大社','伏見稲荷大社'],['丸亀市が全国シェアの多くを占める伝統工芸品は？','うちわ','扇子','和傘','提灯']]],
  [38, '愛媛県', 47, 29, [['県庁所在地は？','松山市','今治市','新居浜市','西条市'],['生産量全国トップクラスの柑橘類は？','みかん','りんご','もも','ぶどう'],['夏目漱石の小説「坊っちゃん」の舞台となった温泉は？','道後温泉','有馬温泉','草津温泉','別府温泉'],['今治市が生産量日本一を誇る綿製品は？','タオル','デニム','シルク','帆布'],['広島県と愛媛県の島々を橋で結ぶ道路は？','しまなみ海道','瀬戸大橋','明石海峡大橋','アクアライン'],['小説「坊っちゃん」の作者は？','夏目漱石','森鴎外','芥川龍之介','太宰治']]],
  [39, '高知県', 48, 30, [['県庁所在地は？','高知市','南国市','四万十市','香南市'],['幕末に薩長同盟の成立に尽力した土佐藩出身の人物は？','坂本龍馬','西郷隆盛','吉田松陰','木戸孝允'],['表面を火で炙って薬味と一緒に食べるカツオの郷土料理は？','カツオのたたき','マグロの解体ショー','鯛めし','ブリの照り焼き'],['「日本最後の清流」と呼ばれる川は？','四万十川','吉野川','仁淀川','長良川'],['鳴子を持って踊る夏のお祭りは？','よさこい祭り','阿波おどり','よさこいソーラン','エイサー'],['高知県が生産量日本一を誇る柑橘類は？','ゆず','すだち','かぼす','みかん']]],
  [40, '福岡県', 42, 28, [['県庁所在地は？','福岡市','北九州市','久留米市','飯塚市'],['スケトウダラの卵巣を唐辛子などで漬け込んだ特産品は？','明太子','筋子','数の子','キャビア'],['菅原道真を祀り、学問の神様として有名な神社は？','太宰府天満宮','北野天満宮','湯島天満宮','防府天満宮'],['豚骨スープと細いストレート麺が特徴のラーメンは？','博多ラーメン','札幌ラーメン','喜多方ラーメン','和歌山ラーメン'],['夜になると街中に並ぶ、食事を提供する移動式の店は？','屋台','キッチンカー','ドライブスルー','フードコート'],['ゴールデンウィークに開催される動員数日本一のお祭りは？','博多どんたく','博多祇園山笠','唐津くんち','長崎くんち']]],
  [41, '佐賀県', 41, 29, [['県庁所在地は？','佐賀市','唐津市','鳥栖市','伊万里市'],['弥生時代の環濠集落跡として有名な遺跡は？','吉野ヶ里遺跡','三内丸山遺跡','登呂遺跡','大森貝塚'],['伊万里焼とも呼ばれる、日本で初めて焼かれた磁器は？','有田焼','九谷焼','備前焼','信楽焼'],['有明海の干潟に生息し、泥の上を跳ねる魚は？','ムツゴロウ','ワラスボ','ハゼ','カレイ'],['県内で育てられる有名な黒毛和牛は？','佐賀牛','松阪牛','神戸牛','近江牛'],['呼子（よぶこ）町で有名な海産物は？','イカ','タコ','カニ','エビ']]],
  [42, '長崎県', 41, 30, [['県庁所在地は？','長崎市','佐世保市','諫早市','大村市'],['南蛮貿易で伝わった、卵と砂糖を使ったスポンジケーキは？','カステラ','バウムクーヘン','マカロン','エクレア'],['幕末に多くの西洋人が住んだ洋風建築が残る観光地は？','グラバー園','異人館街','横浜中華街','出島'],['オランダの街並みを再現した佐世保市のテーマパークは？','ハウステンボス','ディズニーランド','USJ','志摩スペイン村'],['原爆落下の中心地近くに建てられた平和を象徴する像は？','平和祈念像','自由の女神像','クラーク像','西郷隆盛像'],['豚骨・鶏ガラスープに太麺とたっぷりの具材を入れた麺料理は？','ちゃんぽん','ラーメン','うどん','パスタ']]],
  [43, '熊本県', 43, 29, [['県庁所在地は？','熊本市','八代市','天草市','玉名市'],['加藤清正が築いた、黒と白のコントラストが美しいお城は？','熊本城','大阪城','姫路城','名古屋城'],['世界最大級のカルデラを持つ活火山は？','阿蘇山','桜島','富士山','雲仙岳'],['赤いほっぺが特徴の熊本県の有名なPRキャラクターは？','くまモン','ひこにゃん','ふなっしー','せんとくん'],['熊本名物として知られる肉料理は？','馬刺し','牛タン','ジンギスカン','地鶏の炭火焼き'],['熊本県が生産量日本一を誇る夏の果実（野菜）は？','スイカ','メロン','いちご','マンゴー']]],
  [44, '大分県', 44, 28, [['県庁所在地は？','大分市','別府市','中津市','日田市'],['源泉数・湧出量ともに日本一の温泉都市は？','別府温泉','草津温泉','有馬温泉','下呂温泉'],['大分県が生産量日本一を誇る柑橘類は？','かぼす','すだち','ゆず','シークワーサー'],['鶏肉に衣をつけて揚げた大分県の郷土料理は？','とり天','唐揚げ','チキン南蛮','フライドチキン'],['由布岳の麓に広がる、女性に人気の温泉地は？','湯布院','黒川温泉','道後温泉','城崎温泉'],['様々な色の温泉を巡る別府の観光の定番は？','地獄めぐり','湯めぐり','外湯めぐり','砂湯めぐり']]],
  [45, '宮崎県', 43, 30, [['県庁所在地は？','宮崎市','都城市','延岡市','日向市'],['揚げた鶏肉に甘酢とタルタルソースをかけた料理は？','チキン南蛮','とり天','唐揚げ','油淋鶏'],['「太陽のタマゴ」などのブランドで知られる南国の果物は？','マンゴー','パイナップル','バナナ','パパイヤ'],['阿蘇の火山活動でできた渓谷で、ボート下りが有名なのは？','高千穂峡','耶馬渓','瀞峡','黒部峡谷'],['サンメッセ日南にある、イースター島公認の石像は？','モアイ像','スフィンクス','マーライオン','自由の女神像'],['宮崎県原産の、黄色くてさっぱりした甘さの柑橘類は？','日向夏','みかん','いよかん','デコポン']]],
  [46, '鹿児島県', 42, 31, [['県庁所在地は？','鹿児島市','霧島市','鹿屋市','薩摩川内市'],['鹿児島湾（錦江湾）に浮かぶ、現在も活動を続ける活火山は？','桜島','阿蘇山','雲仙岳','浅間山'],['鹿児島特産の、六白と呼ばれる豚の品種は？','黒豚','イベリコ豚','アグー豚','金華豚'],['明治維新の立役者で、上野公園に銅像がある人物は？','西郷隆盛','大久保利通','坂本龍馬','木戸孝允'],['別名「唐芋（からいも）」とも呼ばれる特産のイモ類は？','さつまいも','じゃがいも','さといも','やまいも'],['樹齢数千年の縄文杉がある世界自然遺産の島は？','屋久島','種子島','奄美大島','徳之島']]],
  [47, '沖縄県', 9, 36, [['県庁所在地は？','那覇市','沖縄市','うるま市','浦添市'],['琉球王国の政治・外交・文化の中心だった世界遺産のお城は？','首里城','中城城','今帰仁城','座喜味城'],['苦味のある野菜と豆腐、豚肉などを炒めた郷土料理は？','ゴーヤチャンプルー','ラフテー','ソーキそば','海ぶどう'],['家の屋根などに置かれる、魔除けの獅子の像は？','シーサー','狛犬','シャチホコ','シーラカンス'],['巨大なジンベエザメが泳ぐ大水槽で有名な水族館は？','美ら海水族館','海遊館','八景島シーパラダイス','鳥羽水族館'],['かつて沖縄に存在した独立国家は？','琉球王国','大和朝廷','蝦夷島政府','邪馬台国']]]
];

const prefecturesData = prefRawData.map(d => ({
  id: d[0], name: d[1], x: d[2], y: d[3],
  quizzes: d[4].map(q => ({ text: q[0], correct: q[1], options: [q[1], q[2], q[3], q[4]].sort(() => 0.5 - Math.random()) }))
}));

// ドット絵マップレイアウト
const mapLayout = [
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~.^^^*~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~.^^***.~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~..*^^^..~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~.^^^^*..~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~..^^*~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~=~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~..*~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~.^^.~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*^^..~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*.~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*..~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*.~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*..~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*.^..~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*..*~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^.*...*..^~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*.^..~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*..*.~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*..~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*.^..*~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*.^..~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..*~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^..*..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~=~~~~=~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..~~~*..*~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*~~.^..*~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^.~~~~*..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*..*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~=~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~=.~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~..=..=..=..=..=..=..=..=..=..=..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~*..~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",
];
const TILE_SIZE = 40; 

// ==========================================
// ドット絵風アイコンSVG
// ==========================================
const HeroIcon = () => (
  <svg viewBox="0 0 16 16" className="w-4/5 h-4/5 drop-shadow-md">
    <rect x="5" y="2" width="6" height="4" fill="#fbbf24" />
    <rect x="6" y="4" width="4" height="4" fill="#fca5a5" />
    <rect x="5" y="8" width="6" height="5" fill="#3b82f6" />
    <rect x="4" y="9" width="2" height="3" fill="#fca5a5" />
    <rect x="10" y="9" width="2" height="3" fill="#fca5a5" />
    <rect x="5" y="13" width="2" height="3" fill="#9ca3af" />
    <rect x="9" y="13" width="2" height="3" fill="#9ca3af" />
    <rect x="11" y="6" width="1" height="8" fill="#d1d5db" />
    <rect x="10" y="10" width="3" height="1" fill="#fbbf24" />
    <rect x="7" y="5" width="1" height="1" fill="#000" />
    <rect x="9" y="5" width="1" height="1" fill="#000" />
  </svg>
);
const CastleIcon = () => (
  <svg viewBox="0 0 16 16" className="w-4/5 h-4/5 drop-shadow-md animate-bounce">
    <rect x="2" y="6" width="12" height="10" fill="#e5e7eb" />
    <rect x="1" y="4" width="4" height="4" fill="#9ca3af" />
    <rect x="6" y="2" width="4" height="4" fill="#9ca3af" />
    <rect x="11" y="4" width="4" height="4" fill="#9ca3af" />
    <rect x="6" y="12" width="4" height="4" fill="#1f2937" />
    <rect x="3" y="8" width="2" height="2" fill="#3b82f6" />
    <rect x="11" y="8" width="2" height="2" fill="#3b82f6" />
  </svg>
);
const FlagIcon = () => (
  <svg viewBox="0 0 16 16" className="w-3/4 h-3/4 drop-shadow-md opacity-60">
    <rect x="4" y="2" width="2" height="14" fill="#9ca3af" />
    <path d="M6 2 L14 5 L6 8 Z" fill="#ef4444" />
  </svg>
);

// ==========================================
// 3. メインアプリケーション
// ==========================================
export default function App() {
  const [gameState, setGameState] = useState('INIT'); // 初期化用ステートを追加
  const [playerPos, setPlayerPos] = useState({ x: 61, y: 16 });
  const [clearedPrefs, setClearedPrefs] = useState([]); 
  const [encounterPref, setEncounterPref] = useState(null); 
  const [currentBattlePref, setCurrentBattlePref] = useState(null); 

  useEffect(() => {
    const style = document.createElement('style');
    style.innerHTML = `
      @import url('https://fonts.googleapis.com/css2?family=DotGothic16&display=swap');
      .font-dotgothic { font-family: 'DotGothic16', sans-serif; }
      .pixel-window { 
        border: 2px solid white; background-color: black; color: white; 
        border-radius: 4px; box-shadow: inset 0 0 8px rgba(0,0,0,0.5);
      }
      @media (min-width: 640px) { .pixel-window { border-width: 4px; border-radius: 8px; } }
      ::-webkit-scrollbar { width: 0px; background: transparent; }
    `;
    document.head.appendChild(style);
    return () => { document.head.removeChild(style); stopBGM(); };
  }, []);

  const handleMove = useCallback((dx, dy) => {
    if (gameState !== 'FIELD' || encounterPref) return;
    
    setPlayerPos(prev => {
      const nx = prev.x + dx;
      const ny = prev.y + dy;
      
      if (ny < 0 || ny >= mapLayout.length || nx < 0 || nx >= mapLayout[0].length) return prev;
      if (mapLayout[ny][nx] === '~') return prev; // 海はNG
      
      const pref = prefecturesData.find(p => p.x === nx && p.y === ny);
      if (pref && !clearedPrefs.includes(pref.id)) {
        stopBGM();
        playSE('encounter');
        setEncounterPref(pref);
        return prev; 
      }
      playSE('step');
      return { x: nx, y: ny };
    });
  }, [gameState, encounterPref, clearedPrefs]);

  useEffect(() => {
    const handleKeyDown = (e) => {
      switch(e.key) {
        case 'ArrowUp': case 'w': handleMove(0, -1); break;
        case 'ArrowDown': case 's': handleMove(0, 1); break;
        case 'ArrowLeft': case 'a': handleMove(-1, 0); break;
        case 'ArrowRight': case 'd': handleMove(1, 0); break;
        default: break;
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleMove]);

  return (
    <div className="w-screen h-[100dvh] overflow-hidden bg-black font-dotgothic select-none flex justify-center text-white text-sm sm:text-base">
      <div className="w-full max-w-4xl h-full relative border-x-0 sm:border-x-4 border-gray-800 flex flex-col">
        
        {/* 音声初期化のためのスタート画面 */}
        {gameState === 'INIT' && (
          <div className="flex flex-col items-center justify-center w-full h-full cursor-pointer hover:bg-gray-900 transition-colors"
               onClick={() => {
                 initAudio();
                 playBGM('title');
                 setGameState('TITLE');
               }}>
             <div className="pixel-window p-8 text-xl sm:text-3xl animate-pulse text-center leading-loose">
                ♪ サウンドが なります<br/><br/>
                がめん を タップ して<br/>
                はじめる
             </div>
          </div>
        )}

        {gameState === 'TITLE' && <TitleScreen onStart={() => {
            playSE('correct');
            playBGM('field');
            setGameState('FIELD');
        }} />}
        
        {gameState === 'FIELD' && (
          <FieldScreen playerPos={playerPos} clearedPrefs={clearedPrefs} onMove={handleMove} />
        )}
        
        {gameState === 'FIELD' && encounterPref && (
          <EncounterDialog 
            pref={encounterPref} 
            onYes={() => { 
              setCurrentBattlePref(encounterPref);
              setGameState('BATTLE'); 
              setEncounterPref(null); 
              playBGM('battle');
            }} 
            onNo={() => {
              setEncounterPref(null);
              playBGM('field');
            }} 
          />
        )}

        {gameState === 'BATTLE' && currentBattlePref && (
          <BattleScreen 
            pref={currentBattlePref} 
            onWin={(prefId) => {
              const newCleared = [...clearedPrefs, prefId];
              setClearedPrefs(newCleared);
              setCurrentBattlePref(null);
              if (newCleared.length >= 47) {
                stopBGM();
                playSE('clear');
                setGameState('GAMECLEAR');
              } else {
                setGameState('FIELD');
                playBGM('field');
              }
            }} 
            onLose={() => {
              setCurrentBattlePref(null);
              setGameState('FIELD');
              playBGM('field');
            }} 
          />
        )}

        {gameState === 'GAMECLEAR' && <GameClearScreen />}
      </div>
    </div>
  );
}

// ==========================================
function TitleScreen({ onStart }) {
  return (
    <div className="flex flex-col items-center justify-center w-full h-full space-y-8 p-4">
      <h1 className="text-4xl sm:text-6xl md:text-7xl font-bold text-center leading-tight tracking-widest text-yellow-400 drop-shadow-[0_0_10px_rgba(250,204,21,0.8)]">
        都道府県<br/>クエスト
      </h1>
      <button onClick={onStart} className="pixel-window px-6 py-3 sm:px-8 sm:py-4 text-xl sm:text-2xl hover:bg-white hover:text-black transition-colors animate-pulse">
        ぼうけん に でる
      </button>
      <div className="text-gray-400 mt-4 text-center text-sm sm:text-lg leading-loose">
        十字キー または 画面のボタン で いどう<br/>
        47とどうふけん を すべて せいは しよう！
      </div>
    </div>
  );
}

// ==========================================
function Tile({ type }) {
  if (type === '~') return <div className="w-full h-full bg-[#1e3a8a]"></div>;
  if (type === '.') return <div className="w-full h-full bg-[#4ade80] border-t border-l border-[#86efac] opacity-90"></div>;
  if (type === '*') return (
    <div className="w-full h-full bg-[#4ade80] flex justify-center items-center">
      <svg viewBox="0 0 16 16" className="w-3/4 h-3/4">
        <path d="M8 2 L14 8 L10 8 L14 14 L2 14 L6 8 L2 8 Z" fill="#166534" />
      </svg>
    </div>
  );
  if (type === '^') return (
    <div className="w-full h-full bg-[#4ade80] flex justify-center items-center">
       <svg viewBox="0 0 16 16" className="w-full h-full">
        <path d="M8 2 L15 14 L1 14 Z" fill="#854d0e" />
        <path d="M8 2 L11 7 L8 6 L5 7 Z" fill="#fef08a" />
      </svg>
    </div>
  );
  if (type === '=') return (
    <div className="w-full h-full bg-[#1e3a8a] flex justify-center items-center">
      <div className="w-3/5 h-3/5 bg-[#8b5a2b] rounded-sm border border-[#5c3a21]"></div>
    </div>
  );
  return null;
}

// ==========================================
function FieldScreen({ playerPos, clearedPrefs, onMove }) {
  return (
    <div className="w-full h-full relative bg-[#1e3a8a] overflow-hidden">
      <div className="absolute left-1/2 top-1/2 transition-transform duration-200"
           style={{ transform: `translate(calc(-50% - ${playerPos.x * TILE_SIZE}px), calc(-50% - ${playerPos.y * TILE_SIZE}px))` }}>
        
        {mapLayout.map((row, y) => row.split('').map((tile, x) => {
          const pref = prefecturesData.find(p => p.x === x && p.y === y);
          return (
            <div key={`${x}-${y}`} className="absolute" style={{ left: x * TILE_SIZE, top: y * TILE_SIZE, width: TILE_SIZE, height: TILE_SIZE }}>
              <Tile type={tile} />
              {pref && (
                <div className="absolute inset-0 flex items-center justify-center">
                  {clearedPrefs.includes(pref.id) ? <FlagIcon /> : <CastleIcon />}
                </div>
              )}
            </div>
          );
        }))}
        <div className="absolute flex items-center justify-center z-10" 
             style={{ left: playerPos.x * TILE_SIZE, top: playerPos.y * TILE_SIZE, width: TILE_SIZE, height: TILE_SIZE }}><HeroIcon /></div>
      </div>

      <div className="absolute top-2 right-2 sm:top-4 sm:right-4 pixel-window p-2 sm:p-3 z-20 text-sm sm:text-xl">
        せいは: {clearedPrefs.length} / 47
      </div>

      <div className="absolute bottom-4 right-4 sm:bottom-8 sm:right-8 grid grid-cols-3 gap-1 sm:gap-2 opacity-80 z-20">
        <div /><button className="pixel-window w-12 h-12 sm:w-16 sm:h-16 flex items-center justify-center text-xl sm:text-2xl active:bg-gray-500" onClick={() => onMove(0, -1)}>▲</button><div />
        <button className="pixel-window w-12 h-12 sm:w-16 sm:h-16 flex items-center justify-center text-xl sm:text-2xl active:bg-gray-500" onClick={() => onMove(-1, 0)}>◀</button>
        <div className="w-12 h-12 sm:w-16 sm:h-16 flex items-center justify-center bg-gray-900 border border-gray-700 rounded-full"></div>
        <button className="pixel-window w-12 h-12 sm:w-16 sm:h-16 flex items-center justify-center text-xl sm:text-2xl active:bg-gray-500" onClick={() => onMove(1, 0)}>▶</button>
        <div /><button className="pixel-window w-12 h-12 sm:w-16 sm:h-16 flex items-center justify-center text-xl sm:text-2xl active:bg-gray-500" onClick={() => onMove(0, 1)}>▼</button><div />
      </div>
    </div>
  );
}

// ==========================================
function EncounterDialog({ pref, onYes, onNo }) {
  return (
    <div className="absolute inset-0 bg-black bg-opacity-70 flex items-center justify-center z-50 p-4">
      <div className="pixel-window p-4 sm:p-6 w-full max-w-sm sm:max-w-md flex flex-col gap-4 sm:gap-6 animate-pulse border-4 border-yellow-400">
        <p className="text-lg sm:text-2xl leading-relaxed text-center">
          {pref.name} に とうちゃくした！<br/>クイズに ちょうせん しますか？
        </p>
        <div className="flex justify-center sm:justify-end gap-4 mt-2 sm:mt-4 text-base sm:text-xl">
          <button className="pixel-window px-4 py-2 sm:px-6 sm:py-3 hover:bg-white hover:text-black w-24" onClick={() => { playSE('attack'); onYes(); }}>はい</button>
          <button className="pixel-window px-4 py-2 sm:px-6 sm:py-3 hover:bg-white hover:text-black w-24" onClick={() => { playSE('step'); onNo(); }}>いいえ</button>
        </div>
      </div>
    </div>
  );
}

// ==========================================
function BattleScreen({ pref, onWin, onLose }) {
  const [quizzes, setQuizzes] = useState([]);
  const [quizIndex, setQuizIndex] = useState(0); 
  const [enemyHp, setEnemyHp] = useState(3);
  const [playerHp, setPlayerHp] = useState(3);
  
  const [phase, setPhase] = useState('APPEAR'); 
  const [messages, setMessages] = useState([]);
  const [msgIndex, setMsgIndex] = useState(0);

  useEffect(() => {
    const shuffled = [...pref.quizzes].sort(() => 0.5 - Math.random());
    setQuizzes(shuffled);
    setMessages([`あ！ やせいの\n${pref.name} が あらわれた！`]);
    setMsgIndex(0);
    setPhase('APPEAR');
  }, [pref]);

  const handleMessageClick = () => {
    if (phase === 'SELECTING' || quizzes.length === 0) return; 

    if (msgIndex < messages.length - 1) {
      setMsgIndex(msgIndex + 1);
    } else {
      if (phase === 'APPEAR') {
        startNextQuestion(0, quizzes);
      } else if (phase === 'QUESTION') {
        setPhase('SELECTING');
      } else if (phase === 'RESULT') {
        if (enemyHp <= 0) {
          stopBGM();
          playSE('win');
          setPhase('WIN');
          setMessages([`${pref.name} を たおした！`, `ゆうしゃ は\n${pref.name} の ちしき を えた！`]);
          setMsgIndex(0);
        } else if (playerHp <= 0) {
          stopBGM();
          playSE('wrong');
          setPhase('LOSE');
          setMessages([`ゆうしゃ は しんでしまった...`, `もういちど べんきょうして こよう。`]);
          setMsgIndex(0);
        } else {
          startNextQuestion(quizIndex, quizzes);
        }
      } else if (phase === 'WIN') {
        onWin(pref.id);
      } else if (phase === 'LOSE') {
        onLose();
      }
    }
  };

  const startNextQuestion = (index, currentQuizzes) => {
    const safeIndex = index % currentQuizzes.length;
    const q = currentQuizzes[safeIndex];
    setPhase('QUESTION');
    setMessages([`${pref.name} の こうげき！`, q.text]);
    setMsgIndex(0);
  };

  const handleOptionClick = (selected) => {
    const safeIndex = quizIndex % quizzes.length;
    const q = quizzes[safeIndex];
    
    if (selected === q.correct) {
      playSE('attack');
      setTimeout(() => playSE('correct'), 200);
      setEnemyHp(h => h - 1);
      setMessages(["ゆうしゃ の こうげき！", "せいかい だ！", `${pref.name} に 1 の ダメージ！`]);
    } else {
      playSE('wrong');
      setPlayerHp(h => h - 1);
      setMessages(["ゆうしゃ は まちがえた！", "ミス！", `ゆうしゃ は 1 の ダメージを うけた！\n(せいかい: ${q.correct})`]);
    }
    setPhase('RESULT');
    setMsgIndex(0);
    setQuizIndex(i => i + 1);
  };

  const renderText = (text) => text.split('\n').map((line, i) => <React.Fragment key={i}>{line}<br /></React.Fragment>);
  const toFullWidth = (num) => String(num).replace(/[0-9]/g, s => String.fromCharCode(s.charCodeAt(0) + 0xFEE0));
  const currentSafeIndex = quizIndex % quizzes.length;

  return (
    <div className="w-full h-full flex flex-col p-2 sm:p-4 bg-black relative overflow-hidden" onClick={handleMessageClick}>
      <div className="flex justify-between items-start gap-2 sm:gap-4 mb-2 sm:mb-4 text-xs sm:text-lg">
        <div className="pixel-window p-2 sm:p-4 flex-1">
          ゆうしゃ<br/>ＨＰ： {toFullWidth(playerHp)}<br/>（あと {playerHp} ミス）
        </div>
        <div className="pixel-window p-2 sm:p-4 flex-1 text-right">
          {pref.name}<br/>ＨＰ： {toFullWidth(enemyHp)}<br/>（あと {enemyHp} 問）
        </div>
      </div>

      <div className="flex-1 flex items-center justify-center min-h-[100px]">
        <div className={`text-4xl sm:text-6xl md:text-8xl font-bold tracking-widest bg-clip-text text-transparent bg-gradient-to-b from-white to-gray-400 drop-shadow-[0_0_15px_rgba(255,255,255,0.5)] text-center
            ${phase === 'RESULT' && messages[1] === 'せいかい だ！' ? 'animate-ping' : ''}
            ${phase === 'APPEAR' ? 'animate-bounce' : ''} `}>
          {pref.name}
        </div>
      </div>

      <div className="h-2/5 sm:h-1/3 min-h-[160px] max-h-[250px] flex flex-col sm:flex-row gap-2 sm:gap-4 mt-2">
        <div className="flex-1 pixel-window p-3 sm:p-6 relative text-base sm:text-2xl leading-relaxed cursor-pointer overflow-y-auto">
          {messages[msgIndex] && renderText(messages[msgIndex])}
          {phase !== 'SELECTING' && <div className="absolute bottom-2 right-3 sm:bottom-4 sm:right-5 animate-pulse text-lg sm:text-2xl">▼</div>}
        </div>

        {phase === 'SELECTING' && quizzes.length > 0 && (
          <div className="w-full sm:w-2/5 h-full pixel-window p-2 sm:p-4 flex flex-col gap-1 sm:gap-2 overflow-y-auto">
            {quizzes[currentSafeIndex]?.options.map((opt, i) => (
              <button key={i} className="text-left p-1 sm:p-2 hover:bg-white hover:text-black rounded text-sm sm:text-xl transition-colors flex-1"
                onClick={(e) => { e.stopPropagation(); handleOptionClick(opt); }}>
                ▶ {opt}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ==========================================
function GameClearScreen() {
  return (
    <div className="flex flex-col items-center justify-center w-full h-full space-y-8 bg-black p-4">
      <h1 className="text-3xl sm:text-5xl md:text-6xl font-bold text-center leading-tight text-yellow-400 animate-bounce">
        おめでとう！<br/>にほん ぜんこく せいは！
      </h1>
      <div className="text-base sm:text-2xl text-white text-center leading-loose pixel-window p-4 sm:p-8">
        ゆうしゃ は 47とどうふけん の<br/>すべての ちしき を てにいれた。<br/><br/>そして でんせつ へ...
      </div>
      <button onClick={() => window.location.reload()} className="pixel-window px-6 py-3 sm:px-8 sm:py-4 text-lg sm:text-xl hover:bg-white hover:text-black mt-4">
        はじめから 遊ぶ
      </button>
    </div>
  );
}


