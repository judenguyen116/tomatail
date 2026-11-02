const fs=require('fs');const h=fs.readFileSync('index.html','utf8');
const L=h.split('//#LOGIC-START')[1].split('//#LOGIC-END')[0];
const m=new Function(L+';return {MAX_HAPPY,TASKS,dayKey,daysBetween,newGame,sync,completeTask,rescue,needsNewPet,plantStage,moodOf,streakNow,absentDays,tasksDone}')();
const assert=require('assert');
const D=n=>new Date(Date.UTC(2026,0,1+n)).toISOString().slice(0,10);
function full(g,d){m.TASKS.forEach(t=>m.completeTask(g,t,d));}
let g=m.newGame('pig',D(0));
full(g,D(0));assert(g.happiness==7&&g.fruits==2&&g.streak==1);
// skip to day 2 (1 absent day)
m.sync(g,D(2));assert.equal(g.happiness,6);assert.equal(g.fruits,1);assert.equal(g.outbox.join(),'browser');assert.equal(m.plantStage(g,D(2)),'green');
m.sync(g,D(3));assert.equal(m.plantStage(g,D(3)),'brown1');
m.sync(g,D(4));assert.equal(m.plantStage(g,D(4)),'brown2');
m.sync(g,D(5));assert.equal(m.plantStage(g,D(5)),'falling');
m.sync(g,D(7));assert(g.outbox.includes('email')&&g.alive);assert.equal(m.plantStage(g,D(7)),'bare');
m.sync(g,D(8));assert(!g.alive);assert.equal(m.plantStage(g,D(8)),'dead');assert.equal(m.moodOf(g),'dead');
// rescue 5 times
for(let i=0;i<5;i++){assert(m.rescue(g,D(8+i*10),'x'));assert(g.alive&&g.happiness==7&&g.fruits==1);m.sync(g,D(8+i*10+8));assert(!g.alive);}
assert(!m.rescue(g,D(100),'x'));assert(m.needsNewPet(g));
// streak 7
g=m.newGame('fish',D(0));let gift;
for(let i=0;i<7;i++){gift=null;m.TASKS.forEach(t=>{const r=m.completeTask(g,t,D(i));if(r.valid)gift=r.gift;});}
assert.equal(g.streak,7);assert(gift===true);assert.equal(g.fruits,8);
// streak breaks
m.sync(g,D(9));full(g,D(9));assert.equal(g.streak,1);
// partial no valid
g=m.newGame('fish',D(0));m.completeTask(g,'feed',D(1));assert.equal(g.fruits,1);
// sprite widths
const S=h.match(/rows:\[([\s\S]*?)\]\}/g);let bad=0;
const re=/'([.a-z]{5,})'/g;
h.split('const ORDER')[0].split('const SP={')[1].split('\n').forEach((ln,i)=>{let x;const r=/'([.a-zA-Z]+)'/g;while((x=r.exec(ln))){if(x[1].length!==16&&!/^(\w{1,10})$/.test(x[1])){console.log('bad width',x[1].length,x[1]);bad++}}});
console.log('ok bad=',bad);
// one reward per day
{
const L2=h.split('//#LOGIC-START')[1].split('//#LOGIC-END')[0];
const m2=new Function(L2+';return {newGame,completeTask,rescue,sync,TASKS,noteLogin}')();
let g=m2.newGame('pig',D(0));
m2.TASKS.forEach(t=>m2.completeTask(g,t,D(0)));assert.equal(g.fruits,2);
// repeat same day: no more
m2.TASKS.forEach(t=>{g.tasks[t]=false;});m2.TASKS.forEach(t=>m2.completeTask(g,t,D(0)));assert.equal(g.fruits,2);assert.equal(g.happiness,7);
// time going backwards: no reward
m2.TASKS.forEach(t=>{g.tasks[t]=false;});m2.TASKS.forEach(t=>m2.completeTask(g,t,D(-1)));assert.equal(g.fruits,2);
// rescue same day cannot be farmed
g.alive=false;m2.rescue(g,D(0),'x');m2.TASKS.forEach(t=>m2.completeTask(g,t,D(0)));assert.equal(g.fruits,1);
m2.TASKS.forEach(t=>m2.completeTask(g,t,D(1)));assert.equal(g.fruits,2);
assert.equal(m2.noteLogin(g,D(1)),1);assert.equal(m2.noteLogin(g,D(1)),2);assert.equal(m2.noteLogin(g,D(2)),1);
console.log('daily reward ok');
}
