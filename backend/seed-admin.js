require('dotenv').config();
const bcrypt=require('bcryptjs'),mysql=require('mysql2/promise');
(async()=>{
  const[u,e,p]=process.argv.slice(2);
  if(!p){console.log('Usage: node seed-admin.js <username> <email> <password>');process.exit(1)}
  const db=await mysql.createConnection({host:process.env.DB_HOST,user:process.env.DB_USER,password:process.env.DB_PASSWORD,database:process.env.DB_NAME});
  await db.execute(`INSERT INTO users(username,email,password_hash,role) VALUES(?,?,?,'ADMIN')`,[u,e.toLowerCase(),await bcrypt.hash(p,12)]);
  console.log('Admin created: '+u);process.exit(0);
})().catch(x=>{console.error(x.message);process.exit(1)});
