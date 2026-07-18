/* OrzPlayer library UI — intentionally dependency-free apart from Alpine. */
const ORZ_COLORS={modules:'#8be9fd',retro:'#fbbf24',synth:'#39e58c',standard:'#a1a1aa',other:'#94a3b8'};
const ORZ_FORMATS = [
    ...(globalThis.ORZ_DECODER_FORMATS||[]).map(item=>({...item,color:ORZ_COLORS[item.group]||ORZ_COLORS.other})),
    ...[['mp3','MP3'],['ogg','OGG'],['flac','FLAC'],['wav','WAV'],['m4a','M4A'],['aac','AAC']].map(([id,label])=>({id,label,group:'standard',color:ORZ_COLORS.standard}))
];
const ORZ_GROUPS=[['modules','模块音乐'],['retro','复古主机'],['synth','芯片与合成'],['standard','常规音频'],['other','其他格式']];
const clamp=(value,min=0,max=1)=>Math.min(max,Math.max(min,Number(value)||0));
const formatClock=seconds=>{if(!Number.isFinite(Number(seconds))||Number(seconds)<0)return '0:00';const n=Math.floor(Number(seconds)),h=Math.floor(n/3600),m=Math.floor(n%3600/60),s=String(n%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${s}`:`${m}:${s}`};
const formatDuration=seconds=>Number.isFinite(Number(seconds))&&Number(seconds)>0?formatClock(seconds):'—';
const isEditableTarget=target=>Boolean(target?.closest?.('input,textarea,select,[contenteditable="true"]'));
const releaseShortcutFocus=()=>{const active=document.activeElement;if(active&&active!==document.body&&active.matches?.('button,[tabindex]'))active.blur()};
const shortcutAction=(event,editable=isEditableTarget(event.target))=>{
    const key=event.key?.toLowerCase();
    if((event.metaKey||event.ctrlKey)&&key==='k') return 'search';
    if(editable) return key==='escape'?'escape':null;
    return ({' ':'play','arrowleft':event.shiftKey?'back15':'back5','arrowright':event.shiftKey?'forward15':'forward5','arrowup':'volumeUp','arrowdown':'volumeDown','m':'mute','n':'next','p':'prev','/':'search','q':'queue','?':'help','h':'help','escape':'escape'})[key]||null;
};

let player=null;
function playerApp(){return{
    songs:[],page:1,perPage:50,hasMore:false,isLoading:false,totalResults:0,searchQuery:'',formatFilter:'',formatCounts:{},libraryTotal:0,
    currentSong:null,selectedSong:null,queue:[],queueIndex:-1,isPlaying:false,isLoadingTrack:false,volume:.7,lastVolume:.7,progressPercent:0,currentTime:0,duration:0,seekPreview:null,
    sidebarOpen:false,playlistOpen:false,shortcutOpen:false,playlists:[],newPlaylistName:'',toasts:[],toastId:0,
    shortcuts:[{key:'Space',label:'播放 / 暂停'},{key:'← / →',label:'前后 5 秒'},{key:'Shift + ← / →',label:'前后 15 秒'},{key:'↑ / ↓',label:'调整音量'},{key:'M',label:'静音'},{key:'P / N',label:'上一首 / 下一首'},{key:'⌘K 或 /',label:'搜索'},{key:'Q',label:'播放队列'},{key:'? 或 H',label:'显示快捷键帮助'},{key:'Esc',label:'关闭面板 / 清空搜索'}],
    async init(){
        player=new OrzAudioPlayer(); player.volume=this.volume; this.attachPlayerCallbacks(); player.initWasm();
        await Promise.all([this.loadFormatCounts(),this.loadSongs(),this.loadPlaylists()]);
        window.addEventListener('scroll',()=>this.onScroll(),{passive:true});
    },
    attachPlayerCallbacks(){
        player.onTimeUpdate=(ct,dur)=>{this.currentTime=ct;this.duration=dur;this.isPlaying=player.isPlaying;this.progressPercent=dur>0?clamp(ct/dur)*100:0;if(dur>0&&this.currentSong&&!this.currentSong.duration)this.currentSong.duration=dur};
        player.onEnded=()=>this.next(); player.onPlaybackStateChange=value=>{this.isPlaying=value;this.isLoadingTrack=false};
        player.onError=error=>{this.isLoadingTrack=false;this.notify(`无法播放：${error?.message||'未知错误'}`,'error')};
    },
    get formatGroups(){
        const known=new Set(ORZ_FORMATS.map(x=>x.id)); const extras=Object.keys(this.formatCounts).filter(x=>!known.has(x)).map(id=>({id,label:id.toUpperCase(),group:'other',color:'#9ca3af'}));
        const all=[...ORZ_FORMATS,...extras].filter(x=>(this.formatCounts[x.id]||0)>0).map(x=>({...x,count:this.formatCounts[x.id]}));
        return ORZ_GROUPS.map(([id,label])=>({id,label,items:all.filter(x=>x.group===id)}));
    },
    get activeFormatLabel(){return this.formatFilter?(ORZ_FORMATS.find(x=>x.id===this.formatFilter)?.label||this.formatFilter.toUpperCase()):'全部曲目'},
    get summaryText(){if(this.isLoading&&!this.songs.length)return '正在整理音乐资料库';return this.searchQuery?`“${this.searchQuery}” · ${this.totalResults} 首结果`:`${this.totalResults} 首曲目`},
    get timeDisplay(){return `${this.formatTime(this.currentTime)} / ${this.formatTime(this.duration)}`},
    get nowPlayingMeta(){if(!this.currentSong)return '支持 Native · WASM · Server 解码';const artist=this.currentSong.artist?.name||'未知艺术家';return `${artist} · ${this.currentSong.fileFormat.toUpperCase()} · ${this.strategyLabel(this.currentSong.playStrategy)}`},
    get activeList(){return this.songs.some(s=>s.id===this.currentSong?.id)?this.songs:this.queue},
    get currentIndex(){return this.activeList.findIndex(s=>s.id===this.currentSong?.id)},
    get canPrev(){return this.currentIndex>0},get canNext(){return this.currentIndex>=0&&this.currentIndex<this.activeList.length-1},
    strategyLabel(value){return({directFile:'浏览器直放',wasmDecode:'WASM 实时解码',serverDecode:'服务端解码'})[value]||'自动解码'},
    formatColor(format){return ORZ_FORMATS.find(x=>x.id===format?.toLowerCase())?.color||'#9ca3af'},
    formatTime(seconds){return formatClock(seconds)},formatDuration(seconds){return formatDuration(seconds)},
    formatBytes(bytes){const n=Number(bytes)||0;if(!n)return '—';const units=['B','KB','MB','GB'];const i=Math.min(Math.floor(Math.log(n)/Math.log(1024)),3);return `${(n/1024**i).toFixed(i?1:0)} ${units[i]}`},
    async loadFormatCounts(){try{const res=await fetch('/api/songs/formats');if(!res.ok)throw new Error(`HTTP ${res.status}`);const data=await res.json();this.libraryTotal=Number(data.total)||0;this.formatCounts=Object.fromEntries((data.formats||[]).map(x=>[String(x.format).toLowerCase(),Number(x.count)||0]));return true}catch(error){this.mergeVisibleFormatCounts();this.notify('格式统计加载失败，已显示当前列表中的格式','error');return false}},
    mergeVisibleFormatCounts(){const visible={...this.formatCounts};for(const song of this.songs){const format=String(song.fileFormat||'').toLowerCase();if(format&&!visible[format])visible[format]=this.songs.filter(item=>String(item.fileFormat||'').toLowerCase()===format).length}this.formatCounts=visible;if(!this.libraryTotal)this.libraryTotal=this.totalResults||this.songs.length},
    songURL(page=this.page){const query=new URLSearchParams({page:String(page),per:String(this.perPage)});if(this.formatFilter)query.set('format',this.formatFilter);return `/api/songs?${query}`},
    async loadSongs(){this.isLoading=true;this.page=1;try{const res=await fetch(this.songURL());if(!res.ok)throw new Error(`HTTP ${res.status}`);const data=await res.json();this.songs=data.items||[];this.totalResults=data.metadata?.total||0;this.hasMore=(data.metadata?.page*data.metadata?.per)<this.totalResults;this.mergeVisibleFormatCounts()}catch(error){this.songs=[];this.notify('曲目列表加载失败','error')}finally{this.isLoading=false}},
    async loadMore(){if(this.isLoading||!this.hasMore||this.searchQuery)return;this.isLoading=true;try{const res=await fetch(this.songURL(++this.page));if(!res.ok)throw new Error(`HTTP ${res.status}`);const data=await res.json();this.songs=[...this.songs,...(data.items||[])];this.hasMore=(data.metadata?.page*data.metadata?.per)<(data.metadata?.total||0)}catch(error){this.page--;this.notify('加载更多曲目失败','error')}finally{this.isLoading=false}},
    onScroll(){if(document.documentElement.scrollHeight-window.scrollY-window.innerHeight<240)this.loadMore()},
    async search(){const query=this.searchQuery.trim();if(!query)return this.loadSongs();this.isLoading=true;try{const params=new URLSearchParams({q:query});if(this.formatFilter)params.set('format',this.formatFilter);const res=await fetch(`/api/songs/search?${params}`);if(!res.ok)throw new Error(`HTTP ${res.status}`);this.songs=await res.json();this.totalResults=this.songs.length;this.hasMore=false}catch(error){this.notify('搜索失败','error')}finally{this.isLoading=false}},
    async selectFormat(format){this.formatFilter=format;this.sidebarOpen=false;this.selectedSong=null;if(this.searchQuery.trim())await this.search();else await this.loadSongs()},
    clearSearch(){if(this.searchQuery){this.searchQuery='';this.loadSongs()}else document.querySelector('#songSearch')?.blur()},resetFilters(){this.searchQuery='';this.selectFormat('')},
    async playSong(song){if(!player)return;const request=(this.playRequestGen=(this.playRequestGen||0)+1);this.currentSong=song;this.selectedSong=song;this.isPlaying=false;this.isLoadingTrack=true;this.currentTime=0;this.duration=song.duration||0;this.progressPercent=0;await player.play(song);if(request!==this.playRequestGen||player.currentSong?.id!==song.id)return;this.isLoadingTrack=false;this.isPlaying=player.isPlaying;if(!this.queue.some(s=>s.id===song.id))this.queue.push(song);this.queueIndex=this.queue.findIndex(s=>s.id===song.id)},
    async togglePlay(){if(player&&this.currentSong)this.isPlaying=await player.togglePlay()},
    prev(){if(this.canPrev)this.playSong(this.activeList[this.currentIndex-1])},next(){if(this.canNext)this.playSong(this.activeList[this.currentIndex+1])},
    seek(event){if(!this.currentSong)return;const rect=event.currentTarget.getBoundingClientRect(),pct=clamp((event.clientX-rect.left)/rect.width);this.seekToPercent(pct)},
    seekToPercent(pct){pct=clamp(pct);if(player?.seek(pct)){this.currentTime=pct*this.duration;this.progressPercent=pct*100;return true}return false},
    previewSeek(event){if(!this.duration)return;const rect=event.currentTarget.getBoundingClientRect(),left=clamp(event.clientX-rect.left,0,rect.width);this.seekPreview={left,time:left/rect.width*this.duration}},
    setVolume(){this.volume=clamp(this.volume);if(this.volume>0)this.lastVolume=this.volume;player?.setVolume(this.volume)},
    adjustVolume(delta){this.volume=clamp(this.volume+delta);this.setVolume()},toggleMute(){if(this.volume>0){this.lastVolume=this.volume;this.volume=0}else this.volume=this.lastVolume||.7;this.setVolume()},
    seekRelative(seconds){if(!this.duration)return;this.seekToPercent((this.currentTime+seconds)/this.duration)},
    handleShortcut(event){const action=shortcutAction(event);if(!action)return;event.preventDefault();releaseShortcutFocus();({play:()=>this.togglePlay(),back5:()=>this.seekRelative(-5),forward5:()=>this.seekRelative(5),back15:()=>this.seekRelative(-15),forward15:()=>this.seekRelative(15),volumeUp:()=>this.adjustVolume(.05),volumeDown:()=>this.adjustVolume(-.05),mute:()=>this.toggleMute(),next:()=>this.next(),prev:()=>this.prev(),search:()=>document.querySelector('#songSearch')?.focus(),queue:()=>this.playlistOpen=!this.playlistOpen,help:()=>this.shortcutOpen=true,escape:()=>{if(this.shortcutOpen)this.shortcutOpen=false;else if(this.playlistOpen)this.playlistOpen=false;else if(this.sidebarOpen)this.sidebarOpen=false;else this.clearSearch()}})[action]?.()},
    removeFromQueue(index){this.queue.splice(index,1);if(index<=this.queueIndex)this.queueIndex--},
    async loadPlaylists(){try{const res=await fetch('/api/playlists');this.playlists=await res.json()}catch(error){this.notify('播放列表加载失败','error')}},
    async saveAsPlaylist(){const name=this.newPlaylistName.trim();if(!name||!this.queue.length)return;try{const res=await fetch('/api/playlists',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,description:'',songIds:this.queue.map(song=>song.id)})});if(!res.ok){const payload=await res.json().catch(()=>null);throw new Error(payload?.reason||`HTTP ${res.status}`)}const list=await res.json();this.newPlaylistName='';await this.loadPlaylists();this.notify(`播放列表已保存 · ${list.songCount??this.queue.length} 首`)}catch(error){this.notify(`保存播放列表失败：${error?.message||'未知错误'}`,'error')}},
    async loadPlaylist(id){try{const res=await fetch(`/api/playlists/${id}`),list=await res.json();if(list.songs?.length){this.queue=list.songs;this.playSong(list.songs[0]);this.playlistOpen=false}}catch(error){this.notify('播放列表加载失败','error')}},
    async deletePlaylist(id){try{await fetch(`/api/playlists/${id}`,{method:'DELETE'});this.playlists=this.playlists.filter(x=>x.id!==id)}catch(error){this.notify('删除播放列表失败','error')}},
    notify(message,type='success'){const id=++this.toastId;this.toasts.push({id,message,type});setTimeout(()=>this.dismissToast(id),3600)},dismissToast(id){this.toasts=this.toasts.filter(x=>x.id!==id)}
}}

globalThis.OrzUI={clamp,formatDuration,isEditableTarget,releaseShortcutFocus,shortcutAction,formats:ORZ_FORMATS};
globalThis.playerApp=playerApp;
if(typeof module!=='undefined')module.exports=globalThis.OrzUI;
