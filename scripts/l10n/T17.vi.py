PREFIXES = ("docker.",)

VI = {
    "docker.explain.dangling": "Image không có tag, còn sót lại khi bản build mới thay thế. Không container nào dùng nó. Docker sẽ xóa nó; bạn không mất gì cần thiết.",
    "docker.explain.unused": "Image mà không container nào dùng. Lần sau cần, Docker sẽ tải hoặc build lại.",
    "docker.explain.container": "Container đã dừng. Xóa sẽ mất các tệp đã thay đổi bên trong và log của nó. Các volume nó dùng vẫn được giữ.",
    "docker.explain.anonymousVolume": "Volume không tên, không container nào dùng. Volume có thể chứa cơ sở dữ liệu; hãy kiểm tra trước khi xóa. Không thể khôi phục.",
    "docker.explain.namedVolume": "Volume có tên, hiện không container nào dùng. Nó có thể chứa cơ sở dữ liệu hoặc dữ liệu dự án nên AI Disk Keeper sẽ không xóa. Nếu chắc chắn, hãy chạy `docker volume rm <tên>` trong Terminal.",
    "docker.explain.buildCache": "Bộ nhớ đệm build mà không bản build nào đang dùng. Docker sẽ tạo lại khi cần; vài lần build tới có thể chậm hơn.",
    "docker.card.title": "Docker",
    "docker.diskImage": "Docker lưu mọi thứ trong một tệp ổ đĩa ảo (%@ trên đĩa). Dọn dẹp giải phóng dung lượng bên trong ngay, nhưng bản thân tệp chỉ nhỏ lại khi %@ trả lại dung lượng. Việc này có thể mất một lúc hoặc cần khởi động lại. AI Disk Keeper không bao giờ thay đổi hay xóa tệp ổ đĩa ảo.",
    "docker.diskImage.why": "Vì sao tệp không nhỏ lại ngay?",
    "docker.diskImage.sizes": "%@ trên đĩa · tối đa %@",
    "docker.notRunning": "%@ chưa chạy. Hãy mở nó rồi quét lại để xem image, container và volume.",
    "docker.timedOut": "%@ không phản hồi trong %@ giây. Hãy thử lại sau.",
    "docker.running": "%@ %@ · %@",
    "docker.state.running": "Đang chạy",
    "docker.state.notRunning": "Chưa chạy",
    "docker.state.timedOut": "Không phản hồi",
    "docker.checking": "Đang kiểm tra Docker…",
}
