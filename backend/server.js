require('dotenv').config();
const express=require('express'),helmet=require('helmet'),cookieParser=require('cookie-parser'),bcrypt=require('bcryptjs'),jwt=require('jsonwebtoken'),mysql=require('mysql2/promise');
const rl=require('express-rate-limit'),rateLimit=rl.rateLimit||rl;
const SECRET=process.env.JWT_SECRET;
if(!SECRET)throw new Error('JWT_SECRET missing in .env');
const app=express();
app.set('trust proxy',1);
app.use(helmet());app.use(express.json({limit:'10kb'}));app.use(cookieParser());
const pool=mysql.createPool({host:process.env.DB_HOST,user:process.env.DB_USER,password:process.env.DB_PASSWORD,database:process.env.DB_NAME,connectionLimit:10,dateStrings:true});
const fail=(res,c,m)=>res.status(c).json({success:false,message:m});
const isEmail=s=>typeof s==='string'&&s.length<=120&&/^[^ @]+@[^ @]+[.][^ @]+$/.test(s);
const strong=p=>typeof p==='string'&&p.length>=10&&p.length<=72&&/[a-z]/.test(p)&&/[A-Z]/.test(p)&&/[0-9]/.test(p);
const STATUS=['ACTIVE','ON_LEAVE','RESIGNED'];
const empOk=b=>{const t=(s,m)=>typeof s==='string'&&s.trim().length>0&&s.length<=m;return t(b.full_name,100)&&isEmail(b.email)&&t(b.department,50)&&t(b.designation,50)&&/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(b.joining_date||'')&&STATUS.includes(b.employment_status)};
const auth=(req,res,next)=>{try{req.user=jwt.verify(req.cookies.hrms_token,SECRET);next()}catch(e){fail(res,401,'Please log in')}};
const admin=(req,res,next)=>req.user.role==='ADMIN'?next():fail(res,403,'Administrator access required');
const wrap=f=>(req,res)=>f(req,res).catch(e=>e.code==='ER_DUP_ENTRY'?fail(res,409,'That email or username already exists'):(console.error(e),fail(res,500,'Server error')));
const COLS='employee_id,full_name,email,department,designation,joining_date,employment_status';

app.get('/api/health',wrap(async(req,res)=>{await pool.query('SELECT 1');res.json({success:true,db:'connected'})}));

app.post('/api/auth/signup',wrap(async(req,res)=>{
  const{username,email,password}=req.body||{};
  if(typeof username!=='string'||!/^[A-Za-z0-9_.]{3,30}$/.test(username)||!isEmail(email)||!strong(password))
    return fail(res,400,'Invalid input. Password needs 10+ characters with upper, lower and a digit.');
  const mail=email.trim().toLowerCase();
  const[emp]=await pool.execute('SELECT employee_id FROM employees WHERE email=?',[mail]);
  if(!emp.length)return fail(res,403,'This email is not registered by HR. Ask your administrator.');
  const hash=await bcrypt.hash(password,12);
  await pool.execute(`INSERT INTO users(username,email,password_hash,role,employee_id) VALUES(?,?,?,'EMPLOYEE',?)`,[username,mail,hash,emp[0].employee_id]);
  res.status(201).json({success:true,message:'Account created. You can log in now.'});
}));

app.post('/api/auth/login',rateLimit({windowMs:15*60*1000,max:30}),wrap(async(req,res)=>{
  const{identifier,password}=req.body||{};
  if(typeof identifier!=='string'||typeof password!=='string')return fail(res,400,'Enter username and password');
  const[rows]=await pool.execute('SELECT * FROM users WHERE username=? OR email=?',[identifier,identifier.toLowerCase()]);
  const u=rows[0];
  if(!u||!(await bcrypt.compare(password,u.password_hash)))return fail(res,401,'Invalid username or password');
  const token=jwt.sign({uid:u.user_id,role:u.role,eid:u.employee_id},SECRET,{expiresIn:'30m'});
  res.cookie('hrms_token',token,{httpOnly:true,secure:true,sameSite:'strict',maxAge:1800000});
  res.json({success:true,role:u.role,redirect:u.role==='ADMIN'?'/admin.html':'/employee.html'});
}));

app.post('/api/auth/logout',(req,res)=>{res.clearCookie('hrms_token');res.json({success:true})});
app.get('/api/auth/me',auth,(req,res)=>res.json({success:true,role:req.user.role}));

app.get('/api/employees/me',auth,wrap(async(req,res)=>{
  const[r]=await pool.execute(`SELECT ${COLS} FROM employees WHERE employee_id=?`,[req.user.eid??null]);
  r.length?res.json({success:true,data:r[0]}):fail(res,404,'No employee profile is linked to this account');
}));

app.get('/api/employees',auth,admin,wrap(async(req,res)=>{
  const s='%'+String(req.query.search||'').slice(0,50)+'%';
  const[r]=await pool.execute(`SELECT ${COLS} FROM employees WHERE full_name LIKE ? OR email LIKE ? OR department LIKE ? ORDER BY employee_id DESC LIMIT 200`,[s,s,s]);
  res.json({success:true,data:r});
}));

app.post('/api/employees',auth,admin,wrap(async(req,res)=>{
  const b=req.body||{};
  if(!empOk(b))return fail(res,400,'Invalid employee data. Check every field.');
  const[r]=await pool.execute('INSERT INTO employees(full_name,email,department,designation,joining_date,employment_status) VALUES(?,?,?,?,?,?)',[b.full_name.trim(),b.email.trim().toLowerCase(),b.department.trim(),b.designation.trim(),b.joining_date,b.employment_status]);
  res.status(201).json({success:true,message:'Employee saved in database (ID '+r.insertId+')',employee_id:r.insertId});
}));

app.put('/api/employees/:id',auth,admin,wrap(async(req,res)=>{
  const b=req.body||{};
  if(!empOk(b)||!/^[0-9]+$/.test(req.params.id))return fail(res,400,'Invalid employee data');
  const[r]=await pool.execute('UPDATE employees SET full_name=?,email=?,department=?,designation=?,joining_date=?,employment_status=? WHERE employee_id=?',[b.full_name.trim(),b.email.trim().toLowerCase(),b.department.trim(),b.designation.trim(),b.joining_date,b.employment_status,req.params.id]);
  r.affectedRows?res.json({success:true,message:'Employee updated'}):fail(res,404,'Employee not found');
}));

app.listen(process.env.PORT||3000,process.env.HOST||'0.0.0.0',()=>console.log('HRMS API running'));
